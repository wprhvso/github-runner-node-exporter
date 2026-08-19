# github-runner-node-exporter

Composite-экшены, которые собирают метрики CPU / памяти / диска / сети с
GitHub-hosted раннера и стримят их в любой Prometheus remote write endpoint.

## Что внутри

| Путь | Назначение |
| --- | --- |
| `.github/actions/runner-metrics-start` | Качает node_exporter и Prometheus, запускает их |
| `.github/actions/runner-metrics-mark` | Отмечает текущий выполняющийся шаг |
| `.github/actions/runner-metrics-stop` | Останавливает сборщики, печатает отчёт |
| `.github/workflows/test.yml` | Линтеры, юнит-, интеграционные и e2e-тесты |
| `.github/workflows/smoke.yml` | Ручной прогон против настоящего endpoint'а с проверкой запросом |
| `scripts/` | Вся логика экшенов, вынесенная в bash-скрипты |
| `tests/` | bats-тесты и фейковый приёмник remote write |

## Как использовать в своём workflow

```yaml
permissions:
  contents: read
  actions: read

steps:
  - uses: actions/checkout@v7

  - uses: ./.github/actions/runner-metrics-start
    with:
      remote-write-url: ${{ secrets.PROMETHEUS_REMOTE_WRITE_URL }}
      username: ${{ secrets.PROMETHEUS_REMOTE_WRITE_USERNAME }}
      password: ${{ secrets.PROMETHEUS_REMOTE_WRITE_PASSWORD }}

  - uses: ./.github/actions/runner-metrics-mark
    with:
      step: build

  - name: Build
    run: make build

  - uses: ./.github/actions/runner-metrics-stop
    if: always()
```

`start` идёт сразу после checkout, `mark` — перед каждым шагом, который хочешь
видеть отдельно, `stop` — последним и обязательно с `if: always()`.

С пустым `remote-write-url` все экшены превращаются в no-op, так что их безопасно
держать в workflow до того, как появится endpoint.

`actions: read` нужен, чтобы `start` спросил у API человекочитаемое имя джоба —
то самое, что видно в интерфейсе, с раскрытой матрицей. Без этого права экшен
напишет warning и подставит ключ джоба из YAML. Можно обойтись без API и задать
имя руками: `job-name: ${{ matrix.runner }}`.

Во вложенном reusable workflow это не право, а потолок: джоб не может попросить
`actions: read`, если вызывающий его не даёт, и GitHub бракует такой файл целиком
ещё до запуска. Дефолтные права токена во многих репозиториях — `contents: read`
и больше ничего, так что либо выдавайте `actions: read` вызывающей джобе, либо
просто задавайте `job-name`. С заданным `job-name` экшен в API не ходит вовсе.

## Тесты

`test.yml` гоняет всё на push и pull request:

| Джоб | Что проверяет |
| --- | --- |
| `lint` | shellcheck, actionlint, yamllint |
| `unit` | чистые функции из `scripts/lib.sh`: парсинг exposition-формата, экранирование, валидация входов |
| `integration` | настоящие node_exporter и Prometheus против фейкового приёмника на loopback: доставка, basic auth, preflight 401/404/нет ответа, отчёт |
| `e2e` | сами композитные экшены в джобе |
| `e2e-prometheus` | поднимает настоящий Prometheus с remote write receiver, гоняет джоб с двумя шагами и потом запросами проверяет, что метрики и шаги в нём есть и выглядят как надо |

Юнит и интеграция запускаются через bats. Локально: `bats tests/unit tests/integration`.

## Требования к endpoint'у

Нужен HTTPS и basic auth. Экшен отказывается стартовать с `http://`, кроме
loopback-адресов, которые нужны тестам. Приёмником может быть Prometheus, запущенный с
`--web.enable-remote-write-receiver`, VictoriaMetrics, Mimir или Grafana Cloud.
Пароль летит в каждом запросе, поэтому HTTP без TLS использовать нельзя.

Фильтровать по IP бесполезно: диапазоны GitHub-hosted раннеров динамические.

Перед стартом агента `start` делает preflight-запрос к endpoint'у:

| Ответ | Что делает экшен |
| --- | --- |
| `401`, `403` | Джоб падает сразу: креды не приняты |
| `404` | warning: скорее всего в url забыли `/api/v1/write` |
| `5xx` | warning: приёмник лежит либо не читается его файл с паролями |
| нет ответа | warning, сбор продолжается локально |

Всё остальное считается успехом: на пустое тело приёмник законно отвечает `400`.

## Лейблы

Каждый сэмпл несёт `gha_repository`, `gha_workflow`, `gha_job`, `gha_job_name`,
`gha_run_id`, `gha_run_number`, `gha_run_attempt`, `gha_ref_name`,
`gha_runner_os`, `gha_runner_arch`. Имена шагов приходят как лейбл `step` у
`gha_step_active`.

`gha_job` — ключ джоба из YAML, одинаковый для всех джобов матрицы.
`gha_job_name` — имя из интерфейса, с раскрытой матрицей: `matrix (ubuntu-24.04-arm)`.
Первый стабилен при переименованиях, второй читается человеком; поэтому есть оба.

`instance` собирается как `workflow/имя джоба#номер.попытка` — уникален и при
этом годится для выпадашки в Grafana как есть.

`gha_run_id` высококардинален по своей природе. Держи retention этих серий коротким.

## Какие метрики уезжают

Наружу отправляется только то, по чему видно, что раннер вот-вот умрёт:

- `node_cpu_seconds_total` без шумных режимов (`nice`, `irq`, `softirq`, `guest`)
- `node_memory_*` вместе со swap, `node_load1`, `node_load5`
- `node_vmstat_oom_kill` — сработал ли OOM killer, `node_vmstat_pgmajfault`, свопирование
- `node_pressure_*` (PSI) в вариантах `waiting` и `stalled` — самый ранний признак
  нехватки CPU, памяти или диска; требует `/proc/pressure` на раннере
- `node_disk_*`, `node_network_*`, `node_filesystem_*`
- `gha_step_active` — какой шаг workflow выполняется прямо сейчас

Получается около 60 серий на скрейп: их хватает на дашборд и они не раздувают
приёмник.

## Сколько это стоит джобу

Экшены задуманы так, чтобы их присутствие не искажало то, что они измеряют:

- Prometheus (около 100 МБ) качается только когда remote write включён; при
  локальном сборе тянется один node_exporter
- node_exporter и Prometheus качаются параллельно, с ретраями на сетевые сбои
- оба бинаря живут с `GOMAXPROCS=1` и `GOGC=50`, node_exporter отдаёт только
  нужные коллекторы и не отдаёт собственные `go_*` и `promhttp_*`
- из netdev выкинуты `veth*`, из filesystem — оверлеи докера: на CI с docker
  compose они плодят сотни серий на ровном месте
- `stop` после отчёта удаляет пароль и весь рабочий каталог, освобождая
  примерно 400 МБ диска раннера

По факту это около 20 МБ RSS у node_exporter и около 80 МБ у агента.

## Отчёт в job summary

Числовые входы (`drain-seconds`, `flush-timeout`) при мусорном значении молча
откатываются к дефолту, а не роняют джоб и не оставляют пароль на диске.
`scrape-interval` и версии бинарей, наоборот, проверяются до старта: с
некорректным значением джоб падает сразу, а не через минуту в логах Prometheus.

`stop` пишет в summary таблицу с числом ядер, памятью, свободным местом,
счётчиком OOM kill'ов и накопленным PSI, а также хвосты логов обоих процессов.
Если OOM killer срабатывал, экшен дополнительно ставит warning на джоб — его
видно в списке чеков, не заходя в логи.

Тот же отчёт остаётся на раннере в `$RUNNER_METRICS_ROOT/report.md`, если
выключить `cleanup`.

Входы `stop`: `drain-seconds` (по умолчанию 5 — сколько ещё собирать перед
выключением), `flush-timeout` (30 — сколько ждать досылки), `report` (`true`) и
`cleanup` (`true` — удалять ли бинари и WAL с раннера).

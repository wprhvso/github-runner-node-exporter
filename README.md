# github-runner-node-exporter

Composite-экшены, которые собирают метрики CPU / памяти / диска / сети с
GitHub-hosted раннера и стримят их в любой Prometheus remote write endpoint.

## Что внутри

| Путь | Назначение |
| --- | --- |
| `.github/actions/runner-metrics-start` | Качает node_exporter и Prometheus, запускает их |
| `.github/actions/runner-metrics-mark` | Отмечает текущий выполняющийся шаг |
| `.github/actions/runner-metrics-stop` | Останавливает сборщики, печатает отчёт |
| `.github/workflows/smoke.yml` | Сбор без отправки, отчёт в job summary |
| `.github/workflows/matrix.yml` | То же самое на разных образах раннеров |
| `.github/workflows/remote.yml` | Полный путь с реальной отправкой в remote write |

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

## Требования к endpoint'у

Нужен HTTPS и basic auth. Приёмником может быть Prometheus, запущенный с
`--web.enable-remote-write-receiver`, VictoriaMetrics, Mimir или Grafana Cloud.
Пароль летит в каждом запросе, поэтому HTTP без TLS использовать нельзя.

Фильтровать по IP бесполезно: диапазоны GitHub-hosted раннеров динамические.

Перед стартом агента `start` делает preflight-запрос к endpoint'у. Если тот
отвечает 401 или 403, job падает сразу с внятной ошибкой, а не спустя минуту
среди логов Prometheus.

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

# github-runner-metrics

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

## Что нажать

### Шаг 1. Проверить сбор

Залей репозиторий на GitHub как публичный. Открой вкладку **Actions**, если
GitHub попросит включить workflow'ы — нажми
**I understand my workflows, go ahead and enable them**.

Push в `main` или в ветку `feature/*` сам запустит **Smoke**. Либо запусти
вручную: **Smoke** → **Run workflow** → **Run workflow**. Около трёх минут.

Открой завершившийся прогон, прокрути страницу с итогами вниз. Там блок
**Runner metrics report** с образцом метрик и строкой `remote write: disabled`.

### Шаг 2. Проверить отправку

Добавь три секрета: **Settings** → **Secrets and variables** → **Actions** →
**New repository secret**.

| Имя | Пример значения |
| --- | --- |
| `PROMETHEUS_REMOTE_WRITE_URL` | `https://metrics.example.com/api/v1/write` |
| `PROMETHEUS_REMOTE_WRITE_USERNAME` | `gha` |
| `PROMETHEUS_REMOTE_WRITE_PASSWORD` | пароль |

Запусти **Remote** → **Run workflow**. Job падает, если ни один сэмпл не ушёл
или если часть отправок вернула ошибку.

### Шаг 3. Проверить остальные образы

**Matrix** → **Run workflow**. Пять джобов параллельно.

## Как читать отчёт

Здоровый отчёт содержит:

- `node_cpu_seconds_total` с ненулевым значением
- `node_memory_MemAvailable_bytes`
- `gha_step_active{step="burn-cpu"}` — доказывает, что разметка шагов работает
- в режиме отправки — блок `remote storage` с ненулевым `samples_total`
  и нулевым `samples_failed_total`

Если какой-то секции нет — соответствующий сборщик не отработал. В отчёт также
попадают хвосты логов обоих сборщиков.

## Как использовать в своём workflow

```yaml
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

## Требования к endpoint'у

Нужен HTTPS и basic auth. Приёмником может быть Prometheus, запущенный с
`--web.enable-remote-write-receiver`, VictoriaMetrics, Mimir или Grafana Cloud.
Пароль летит в каждом запросе, поэтому HTTP без TLS использовать нельзя.

Фильтровать по IP бесполезно: диапазоны GitHub-hosted раннеров динамические.

## Цена

Примерно 20 лишних секунд на job: около 10 секунд на скачивание бинарей и
10 секунд слива в конце.

## Лейблы

Каждый сэмпл несёт `gha_repository`, `gha_workflow`, `gha_job`, `gha_run_id`,
`gha_run_attempt`, `gha_ref_name`, `gha_runner_os`, `gha_runner_arch`. Имена шагов
приходят как лейбл `step` у `gha_step_active`.

`gha_run_id` высококардинален по своей природе. Держи retention этих серий коротким.

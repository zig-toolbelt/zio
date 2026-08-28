# zio — аналитический документ и дорожная карта

> Статус: черновик v1 · Целевой тулчейн: **Zig 0.16** · Целевой релиз: **0.3.0**
> Референсы: [Dio](https://pub.dev/packages/dio) (Dart), [req](https://req.cool/) (Go)

---

## 1. Резюме

`zio` задуман как HTTP-клиент «с батарейками» в духе Dio и req, но идиоматичный для Zig и без внешних зависимостей — только `std`.

**Где мы сейчас.** ~715 строк, 5 файлов. Реализовано: `Client` с `base_url`, шесть HTTP-методов, сырой `?[]const u8` в качестве тела, заголовки навылет, `Response{status, body, headers}` с `getHeader()`, декомпрессия gzip/deflate/zstd. От совокупного функционала Dio + req это меньше 10%.

**Блокер.** Библиотека **не собирается на Zig 0.16**:
- `std.http.Client` получил обязательное поле `io: Io` без дефолта — `client.zig:23` (`.{ .allocator = allocator }`) больше не компилируется;
- `std.net` переехал в `std.Io.net` с другой сигнатурой `listen` — ломается весь `client_test.zig`.

**Куда идём.** Три уровня зрелости (base / medium / advanced), одиннадцать фаз, три публикуемых релиза:

| Релиз | Что закрывает |
|---|---|
| `0.3.0` | Полный **base**: корректный HTTP-клиент с query/path params, JSON, таймаутами, редиректами, типизированными ошибками |
| `0.4.0` | Полный **medium**: interceptors, retry, cookies, multipart, streaming, отмена, proxy, dump |
| `0.5.0`+ | **advanced**: pluggable transport, trace, кэш, SSE, HTTP/2 |

**Принцип, которого держимся.** Zero external dependencies. Всё, чего нет в `std` (brotli, QUIC), либо пишется руками, либо явно выносится за область видимости.

---

## 2. Базовые принципы дизайна

Мы берём у Dio и req **идеи**, а не реализацию. Dart и Go диктуют свои паттерны (объекты-билдеры, рантайм-рефлексия, GC), в Zig эти же задачи решаются иначе.

| Аспект | Решение | Обоснование |
|---|---|---|
| **Конфигурация** | Options-структуры с дефолтами: `client.get("/users", .{ .query = ..., .timeout = ... })` | Anonymous struct literals — родной механизм Zig. Fluent-билдер в стиле req (`R().SetHeader().Get()`) требует мутабельного состояния и аллокатора на каждое звено цепочки, а в Zig ещё и не даёт спрятать ошибки: `!*Request` не чейнится |
| **`std.Io`** | Явный параметр: `Client.init(allocator, io, .{})` | Обязателен в `std.http.Client` 0.16. Явная передача даёт пользователю выбор `Threaded`/`Evented` и открывает таймауты, отмену и параллелизм через `io.concurrent` + `Future.cancel` |
| **Владение памятью** | `Response` владеет собственной ареной → `res.deinit()` **без** аллокатора | Сейчас `Response.deinit(allocator)` — пользователь обязан помнить, какой аллокатор передать. Арена внутри ответа убирает целый класс ошибок и удешевляет освобождение десятков мелких строк (заголовки, cookies, final_url) |
| **Ошибки** | Явный `zio.Error` + опциональный `*Diagnostics` out-параметр | Сейчас наружу утекает inferred error set из `std` (`Uri.ParseError ‖ RequestError ‖ ReceiveHeadError ‖ …`) — API нестабилен и невозможно исчерпывающе обработать. `Diagnostics` — паттерн `std.zig.Ast` и `std.Build`: узкий error set + структура с деталями |
| **Расширяемость** | vtable-структуры (`*anyopaque` + указатели на функции) для interceptor / transport / cookie jar | Как `std.mem.Allocator` и `std.Io.VTable`. Без наследования и без аллокаций на диспетчеризацию |
| **JSON** | comptime-дженерики: `try res.json(User, .{})` → `std.json.Parsed(User)` | Zig делает на этапе компиляции то, для чего Go нужны теги и рефлексия, а Dart'у — codegen |
| **Статус-коды** | Не-2xx **не** ошибка по умолчанию; политика `validate_status` | Поведение req (`IsSuccessState()`), которое честнее: тело ошибки часто нужно распарсить. Dio-поведение включается опцией |
| **Именование файлов** | Файл-как-тип → TitleCase: `Client.zig`, `Response.zig` | Конвенция Zig. Сейчас `client.zig` с `const Client = @This()` |
| **Тестируемость** | Вся чистая логика (URL, заголовки, cookies, backoff, multipart) — в модулях без сокетов | Позволяет иметь быстрый оффлайн `zig build test` и не зависеть от сети в CI |

---

## 3. Инвентаризация функционала Dio и req

Легенда: ✅ есть · ⚠️ частично · ❌ нет · — не применимо

### 3.1. URL и параметры

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| `base_url` | `BaseOptions.baseUrl` | `SetBaseURL` | ⚠️ конкатенация без нормализации | base |
| Резолюция относительных URL | ✅ | ✅ | ❌ `allocPrint("{s}{s}")` | base |
| Абсолютный URL перекрывает base | ✅ | ✅ | ⚠️ только по префиксу `http://`/`https://` | base |
| Path params `/users/{id}` | ❌ | `SetPathParam(s)` | ❌ | base |
| Query params | `queryParameters` | `SetQueryParam(s)`, `SetQueryString` | ❌ | base |
| Сериализация массивов в query | `ListFormat`: multi/csv/ssv/pipes/repeat/dots | multi | ❌ | base |
| Общие query на клиенте | ✅ | `SetCommonQueryParam` | ❌ | base |
| Raw / уже закодированный URL | ✅ | ✅ | ❌ | base |

### 3.2. Заголовки

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Per-request заголовки | ✅ | `SetHeader(s)` | ✅ | base |
| Common заголовки на клиенте | `BaseOptions.headers` | `SetCommonHeader(s)` | ❌ | base |
| Merge client ⊕ request с override | ✅ | ✅ | ❌ | base |
| Case-insensitive доступ | `Headers` | ✅ | ⚠️ только на чтение ответа | base |
| `User-Agent` | ✅ | `SetUserAgent` | ❌ | base |
| Privileged vs extra при редиректе | — | — | ❌ | base |

> **Замечание.** `std.http.Client.Request.Headers` уже различает `host` / `authorization` / `user_agent` / `connection` / `accept_encoding` / `content_type` со значениями `.default | .omit | .override`. Наш слой common-заголовков обязан маппиться **сюда**, иначе получим дублирующиеся заголовки в проводе.

### 3.3. Тело запроса

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Raw bytes / string | ✅ | `SetBodyBytes`, `SetBodyString` | ✅ | base |
| JSON marshal | автоматически | `SetBodyJsonMarshal`, авто по Content-Type | ❌ | base |
| `application/x-www-form-urlencoded` | ✅ | `SetFormData` | ❌ | base |
| Авто Content-Type | ✅ | ✅ | ❌ | base |
| `multipart/form-data` | `FormData` + `MultipartFile` | `SetFile(s)`, `SetFileBytes`, `SetFileReader` | ❌ | medium |
| Тело из потока / reader | ✅ | ✅ | ❌ | medium |
| XML | ❌ | `SetBodyXmlMarshal` | ❌ | вне области |
| gzip запроса | `requestEncoder` | ❌ | ❌ | advanced |

### 3.4. Ответ

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Status code | ✅ | `GetStatusCode` | ✅ | base |
| Reason phrase | `statusMessage` | `GetStatus` | ❌ | base |
| HTTP version | ❌ | ✅ | ❌ | base |
| Заголовки ответа | ✅ | `GetHeader` | ✅ | base |
| `isSuccess` / `isError` | `validateStatus` | `IsSuccessState`, `IsErrorState` | ❌ | base |
| Body как текст | `ResponseType.plain` | `String()`, `ToString()` | ⚠️ сырые байты | base |
| Body как байты | `ResponseType.bytes` | `Bytes()` | ✅ | base |
| Типизированный JSON-разбор | `ResponseType.json` | `Into`, `SetSuccessResult`, `SetErrorResult` | ❌ | base |
| Final URL после редиректов | `isRedirect`, `redirects` | ✅ | ❌ | base |
| Body как поток | `ResponseType.stream` | ✅ | ❌ | medium |
| Body в файл | `download()` | `ToFile`, `SetOutputFile` | ❌ | medium |
| Cookies ответа | ✅ | `GetCookies` | ❌ | medium |
| Auto-decode charset → utf-8 | `responseDecoder` | ✅ (фирменная фича) | ❌ | medium |
| Декомпрессия gzip/deflate/zstd | ✅ | ✅ | ✅ | base |
| Декомпрессия brotli | ✅ | ✅ | ❌ | вне области (нет в `std`) |

### 3.5. Тайминги и управление

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Connect timeout | `connectTimeout` | `SetTimeout` | ❌ | base |
| Total timeout | — | `SetTimeout` | ❌ | base |
| Send / receive timeout | `sendTimeout`, `receiveTimeout` | ✅ | ❌ | medium |
| Отмена | `CancelToken` | `SetContext` | ❌ | medium |
| Keep-alive / пул соединений | `persistentConnection` | ✅ | ⚠️ неявно из `std` | base |
| Размеры буферов | ❌ | ✅ | ❌ | base |

### 3.6. Редиректы

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Вкл/выкл | `followRedirects` | `SetRedirectPolicy(NoRedirect)` | ❌ | base |
| Max redirects | `maxRedirects` | `MaxRedirectPolicy` | ⚠️ жёстко 3 из `std` | base |
| Политики по домену/хосту | ❌ | `SameDomain`, `SameHost`, `AllowedHost`, `AllowedDomain` | ❌ | medium |

### 3.7. Надёжность

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Retry count | плагин `dio_smart_retry` | `SetRetryCount` | ❌ | medium |
| Фиксированный интервал | плагин | `SetRetryFixedInterval` | ❌ | medium |
| Exponential backoff + jitter | плагин | `SetRetryBackoffInterval` | ❌ | medium |
| Кастомный интервал | плагин | `SetRetryInterval` | ❌ | medium |
| Уважение `Retry-After` | плагин | ✅ | ❌ | medium |
| Retry conditions | плагин | `AddRetryCondition` | ❌ | medium |
| Retry hooks (обновить токен) | плагин | `AddRetryHook` | ❌ | medium |

### 3.8. Middleware

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Хук на запрос | `Interceptor.onRequest` | `OnBeforeRequest` | ❌ | medium |
| Хук на ответ | `Interceptor.onResponse` | `OnAfterResponse` | ❌ | medium |
| Хук на ошибку | `Interceptor.onError` | `OnError` | ❌ | medium |
| Управление потоком: next / resolve / reject | ✅ | ❌ | ❌ | medium |
| Последовательный interceptor (refresh token) | `QueuedInterceptor` | ❌ | ❌ | medium |
| Логирующий interceptor | `LogInterceptor` | `EnableDebugLog` | ❌ | medium |
| Транспортный middleware | `HttpClientAdapter` | `WrapRoundTripFunc` | ❌ | advanced |

### 3.9. Состояние

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Cookie jar | плагин `dio_cookie_manager` | `SetCookieJar`, `GetCookies`, `ClearCookies` | ❌ | medium |
| Ручная установка cookies | ✅ | `SetCookies` | ❌ | medium |
| Кэш ответов | плагин `dio_cache_interceptor` | ❌ | ❌ | advanced |

### 3.10. Сеть и транспорт

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| HTTP proxy (forward, absolute-URI) | через адаптер | `SetProxyURL`, `SetProxy` | ✅ | medium |
| HTTPS через proxy | ✅ | ✅ | ⛔ запрещён, см. §7.1 | medium |
| Proxy из переменных окружения | ✅ | ✅ | ✅ | medium |
| `NO_PROXY` bypass | ✅ | ✅ | ✅ | medium |
| `Proxy-Authorization` | ✅ | ✅ | ✅ | medium |
| CONNECT-туннель | ✅ | ✅ | ⛔ заблокирован в `std` | medium |
| Unix socket | ❌ | `SetUnixSocket` | ❌ | medium |
| Pluggable transport | `HttpClientAdapter` | экспортируемый `Transport` | ❌ | advanced |
| HTTP/2 | плагин `dio_http2_adapter` | `EnableForceHTTP2` | ❌ | advanced |
| HTTP/3 | ❌ | `EnableHTTP3` | ❌ | вне области (нет QUIC в `std`) |

### 3.11. TLS

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Кастомный CA bundle | `SecurityContext` | `SetRootCertsFromFile` | ❌ | medium |
| Клиентский сертификат | ✅ | `SetCertFromFile` | ❌ | medium |
| Insecure skip verify | `badCertificateCallback` | `EnableInsecureSkipVerify` | ❌ | medium |
| `SSLKEYLOGFILE` | ❌ | ✅ | ❌ | medium |
| Certificate pinning | ✅ | ✅ | ❌ | advanced |
| TLS/JA3 fingerprint impersonation | ❌ | `SetTLSFingerprintChrome` и др. | ❌ | advanced |
| HTTP fingerprint (порядок заголовков) | ❌ | `ImpersonateChrome` и др. | ❌ | advanced |

### 3.12. Прогресс и файлы

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Прогресс отправки | `onSendProgress` | `SetUploadCallback` | ❌ | medium |
| Прогресс получения | `onReceiveProgress` | `SetDownloadCallback` | ❌ | medium |
| Троттлинг колбэка | ❌ | `SetUploadCallbackWithInterval` | ❌ | medium |
| Скачивание в файл | `download()` | `SetOutputFile` | ❌ | medium |
| Удалять файл при ошибке | `deleteOnError` | ❌ | ❌ | medium |
| Range / докачка | ❌ | ❌ | ❌ | advanced |

### 3.13. Наблюдаемость

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Dump запроса/ответа | `LogInterceptor` | `EnableDumpAll`, `EnableDump` | ❌ | medium |
| Debug-лог | ✅ | `EnableDebugLog`, `SetLogger` | ❌ | medium |
| Dev-режим одной кнопкой | ❌ | `req.DevMode()` | ❌ | medium |
| Редакция секретов в логе | ❌ | ❌ | ❌ | medium |
| Trace по фазам (DNS/connect/TLS/TTFB) | ❌ | `EnableTraceAll`, `TraceInfo` | ❌ | advanced |
| Хуки для метрик (Prometheus/OTel) | ❌ | через middleware | ❌ | advanced |
| Экспорт запроса в `curl` | ❌ | ❌ | ❌ | advanced |

### 3.14. Аутентификация

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Basic | вручную | `SetBasicAuth` | ❌ | base |
| Bearer | вручную | `SetBearerAuthToken` | ❌ | base |
| Digest | ❌ | `SetDigestAuth` | ❌ | advanced |

### 3.15. Тестирование

| Фича | Dio | req | zio сейчас | Уровень |
|---|---|---|---|---|
| Mock-адаптер / in-memory transport | `HttpClientAdapter` | httpmock | ❌ | advanced |
| Loopback-сервер в тестах | — | — | ✅ | base |

---

## 4. Сводка по уровням

### BASE — «корректный HTTP-клиент, которым не стыдно пользоваться»

1. Порт на Zig 0.16 (`io: Io`, `std.Io.net` в тестах).
2. Резолюция URL через `std.Uri` — нормализация слэшей, относительные пути, абсолютный override.
3. Path params и query params с политикой сериализации массивов.
4. Все методы + `OPTIONS` / `TRACE` + generic `request(method, …)`.
5. Common заголовки на клиенте + merge с per-request, с маппингом на `std.http.Client.Request.Headers`.
6. Тело: bytes / string / JSON / urlencoded form + авто Content-Type.
7. `Response`: status, reason, version, headers, body, `final_url`, `content_type`; собственная арена, `deinit()`; `isSuccess()`, `text()`, `json(T, .{})`.
8. `zio.Error` + `Diagnostics`.
9. `validate_status`.
10. Таймауты: connect + total.
11. Управление редиректами + `final_url`.
12. Basic / Bearer auth.
13. Настройки пула, keep-alive, размеров буферов.
14. Инфраструктура: `build.zig`, CI, версия, оффлайн-тесты.

### MEDIUM — «на уровне Dio из коробки»

1. Interceptor chain (`on_request` / `on_response` / `on_error`).
2. Retry engine (count, fixed / backoff + jitter, `Retry-After`, conditions, hooks).
3. Cookie jar.
4. `multipart/form-data` + `MultipartFile`.
5. Streaming: ответ как reader, download в файл, upload из файла/reader.
6. Progress callbacks (send / receive).
7. Отмена (`CancelToken`) поверх `io.concurrent` + `Future.cancel`.
8. Proxy (явный + из окружения) и unix socket.
9. TLS-конфиг: CA bundle, клиентский сертификат, insecure skip verify, `SSLKEYLOGFILE`.
10. Dump / debug-лог с редакцией секретов.
11. `ResponseType` (bytes / text / json / stream / file) и auto-decode charset.
12. Хелпер параллельных запросов через `io.Group`.

### ADVANCED — «территория req»

1. Pluggable transport (vtable) → mock-адаптер для тестов, база для HTTP/2.
2. Trace по фазам + хуки для метрик.
3. Digest auth.
4. Кэш ответов (подмножество RFC 9111, ETag / `If-None-Match`).
5. Rate limiter / circuit breaker как interceptor'ы.
6. HTTP/2.
7. SSE-клиент (`text/event-stream`).
8. Certificate pinning (SPKI hash).
9. Range / докачиваемый download.
10. Экспорт запроса в `curl`.
11. TLS/JA3 fingerprint impersonation.

### Явно вне области видимости

| Что | Почему |
|---|---|
| **brotli** | Нет в `std`; своя реализация — отдельный проект |
| **HTTP/3** | Нет QUIC в `std` |
| **WebSocket-клиент** | В `std` есть только серверная сторона (`std.http.Server.WebSocket`) |
| **XML** | Нет в `std`; ниша уже́ JSON |

---

## 5. Целевая структура модулей

```
src/
  root.zig          — публичные ре-экспорты
  Client.zig        — Client, ClientOptions
  Request.zig       — RequestOptions, сборка запроса, merge опций
  Response.zig      — Response с ареной: text / json / bytes / writeToFile
  Error.zig         — zio.Error, Diagnostics
  url.zig           — join base_url, path params, кодирование query, ListFormat
  headers.zig       — HeaderMap (case-insensitive, с сохранением порядка)
  body/
    json.zig
    form.zig
    multipart.zig
  interceptor.zig   — vtable + chain
  retry.zig         — политики, backoff, Retry-After
  cookie/
    Jar.zig
    parse.zig
  progress.zig
  transport.zig     — Adapter vtable (advanced)
  observe/
    dump.zig
    trace.zig
  testing.zig       — loopback-сервер и mock-адаптер для тестов
examples/           — вместо нынешнего src/main.zig
```

### Эскиз публичного API (ориентир, не контракт)

```zig
var threaded: std.Io.Threaded = .init(allocator);
defer threaded.deinit();

var client = try zio.Client.init(allocator, threaded.io(), .{
    .base_url = "https://api.example.com",
    .headers = &.{ .{ .name = "Accept", .value = "application/json" } },
    .timeout = .{ .duration = .fromMillis(10_000) },
    .retry = .{ .count = 3, .backoff = .{ .min_ms = 100, .max_ms = 2_000 } },
});
defer client.deinit();

var res = try client.get("/users/{id}", .{
    .path_params = &.{ .{ "id", "42" } },
    .query = &.{ .{ "include", "profile" } },
    .auth = .{ .bearer = token },
});
defer res.deinit();

if (!res.isSuccess()) return error.ApiError;

const parsed = try res.json(User, .{});
defer parsed.deinit();
```

---

## 6. Фазы реализации

| Фаза | Содержание | Уровень | Блокирует |
|---|---|---|---|
| **0. Порт на 0.16** | `io: Io` в `Client`; переписать `client_test.zig` на `std.Io.net`; почистить `build.zig`; `minimum_zig_version = "0.16.0"`; версия `0.3.0`; починить утечку `value_dup`; убрать `GetOptions`; CI | — | всё |
| **1. Ядро запроса** | `url.zig`, `headers.zig`, `Error.zig`, `Diagnostics`, merge опций, generic `request()`, `OPTIONS`/`TRACE` | base | 2+ |
| **2. Тело и ответ** | JSON/form-кодеки, авто Content-Type, `Response` с ареной, `text` / `json(T)` / `isSuccess`, `final_url`, `validate_status` | base | 4, 5 |
| **3. Тайминги и сеть** | connect timeout, total timeout, редиректы, auth-хелперы, настройки пула и TLS | base | 5 |
| **4. Middleware** | Interceptor chain, поверх него — retry engine | medium | 6, 8 |
| **5. Потоки и файлы** | Streaming-ответ, download / upload, progress, multipart | medium | — |
| **6. Состояние и транспорт** | Cookie jar, proxy, unix socket, отмена | medium | — |
| **7. Наблюдаемость** | Dump, debug-лог, редакция секретов, `ResponseType`, charset | medium | — |
| **8. Adapter** | Transport vtable + mock-адаптер, `testing.zig` | advanced | 9 |
| **9. Расширения** | Trace, digest, кэш, rate limit, SSE, pinning, Range, curl-экспорт | advanced | — |
| **10. HTTP/2 и fingerprint** | Отдельный трек; оценить целесообразность без внешних зависимостей | advanced | — |

**Точки релиза:** `0.3.0` после фазы 3 · `0.4.0` после фазы 7 · `0.5.0`+ по мере advanced.

---

## 7. Технические заметки по Zig 0.16

Проверено по исходникам `std` в установленном тулчейне. Это фундамент плана — фазы опираются на конкретные API, а не на предположения.

### 7.1. Баг `std`: TLS не накладывается на CONNECT-туннель

**Подтверждено эмпирически** (зонд: фейковый CONNECT-прокси, который читает первые байты после установки туннеля):

```
request line: CONNECT example.com:443 HTTP/1.1
tunnel bytes: 47 45 54 20 2f 20 48 54 54 50 2f 31    ("GET / HTTP/1.1")
```

`std.http.Client` при запросе `https://` через прокси открывает туннель и шлёт в него
**открытый HTTP** — включая `Authorization`. Это не «не работает», это утечка учётных данных.

Механика: `request()` (`:1726`) берёт `*Connection` от `connect()` и TLS поверх не накладывает;
`connect()` (`:1598`) → `connectProxied()` (`:1524`) → `connectTcpOptions(.protocol = proxy.protocol)`,
то есть для `http://`-прокси получается `.plain`-соединение. Второго TLS-слоя в архитектуре
`Connection` просто нет.

Наше решение: `client.https_proxy` **никогда не выставляется**, а `zio` возвращает
`error.HttpsThroughProxyUnsupported`. `Proxy.supports_connect = false`, чтобы `std` шёл
forward-proxy путём (absolute-URI), который для plain HTTP корректен.

**Статус в upstream.** Баг присутствует и в 0.16.0, и в текущем master (проверено по
исходнику с Codeberg: `Tls.create` вызывается только из `connectTcpOptions`, upgrade-логики
после туннеля нет). Известен с 7 мая 2024 — issue #19878, метки bug + standard library,
milestone *urgent*, open, есть непринятый PR #23365. Статус снят с GitHub-зеркала;
канонический трекер теперь на Codeberg и отдаёт анти-скрейпер заглушку.

Вывод: ждать upstream — не стратегия. Разблокировать можно тремя путями: патч в upstream
(два года на urgent без фикса); открыть `Connection.Plain.create` / `Connection.Tls.create`
(сейчас приватные, поэтому свой сокет в `std.http.Client` не отдать); либо свой транспорт
из фазы 8 — единственный путь, полностью в нашем контроле.

> Зига теперь живёт на Codeberg: `https://codeberg.org/ziglang/zig`. GitHub — зеркало,
> его трекер может отставать.

### 7.2. Баг `std`: `http_proxy=host:port` без схемы молча игнорируется

`createProxyFromEnvVar` (`:1344`) делает `Uri.parse(content) catch Uri.parseAfterScheme("http", content)`.
Но `Uri.parse("proxy.corp:3128")` **успешно** разбирает это как схему `proxy.corp` с путём `3128`,
фолбэк не срабатывает, `Protocol.fromUri` возвращает `null` → прокси тихо не применяется.

В `src/proxy.zig` разбор идёт по наличию `"://"`, а не по успеху `Uri.parse`.

### 7.3. Прочее по proxy

- `NO_PROXY` в `std` не реализован вообще — ни в `initDefaultProxies`, ни в `connect()`.
  Реализовано в `src/proxy.zig` по семантике Go `httpproxy` / curl.
- `connect()` применяет `client.http_proxy` безусловно, хука для bypass нет. Обход:
  открыть соединение самим через `connectTcpOptions` и передать в `RequestOptions.connection`.
- `connection.proxied = true` → `std` пишет absolute-URI в request line (`:1002-1004`).
- `proxy-authorization` берётся из `client.http_proxy`/`https_proxy` по `connection.protocol`
  (`:1076-1084`) — значит поле обязано быть выставлено, своей строкой заголовка не обойтись.
- `Tls.create` ассертит `client.now != null`. Он выставляется в `request()` **до** получения
  соединения, поэтому ручной `connectTcpOptions(.protocol = .tls)` до вызова `request()`
  упадёт на ассерте. Для plain такой проблемы нет.

**Клиент.** `std.http.Client` (`std/http/Client.zig:28-64`) имеет поля `allocator`, **`io: Io` (без дефолта)**, `ca_bundle`, `tls_buffer_size`, `ssl_key_log`, `connection_pool`, `read_buffer_size = 8192`, `write_buffer_size = 1024`, `http_proxy`, `https_proxy`. Готовые точки подключения для TLS-конфига, proxy и тюнинга пула — писать своё не нужно.

**Таймауты — главная неочевидность.** `Client.RequestOptions` (`:1633`) **не имеет** поля timeout. Есть только `version`, `handle_continue`, `keep_alive`, `redirect_behavior`, `connection: ?*Connection`, `headers`, `extra_headers`, `privileged_headers`.
- *Connect timeout* достижим единственным путём: `connectTcpOptions(.{ …, .timeout: Io.Timeout })` (`:1435`) → полученный `*Connection` передаётся в `request(.{ .connection = conn })`. Обычные `connectTcp` / `connect` вызывают его с `.timeout = .none`.
- *Total timeout и отмена* строятся на `io.concurrent(fn, args)` → `Future(T)` с `await(io)` / `cancel(io)` (`std/Io.zig:1176`, `:2365`), либо на `Io.Batch.awaitConcurrent(io, timeout)` (`:591`). `Io.Timeout` = `none | duration | deadline` (`:1132`). Это же даёт `CancelToken` из фазы 6.

**Заголовки.** `Request.Headers` — `host`, `authorization`, `user_agent`, `connection`, `accept_encoding`, `content_type`, каждое `.default | .omit | .override`. Common-заголовки обязаны маппиться сюда, иначе в проводе будут дубли. `extra_headers` / `privileged_headers` — **externally-owned, должны пережить `Request`**, значит слой merge'а держит арену на всё время запроса.

**Ответ.** `Response.Head` (`:494`) уже разбирает `version`, `status`, `reason`, `location`, `content_type`, `content_disposition`, `keep_alive`, `content_length`, `transfer_encoding`, `content_encoding` — почти весь base-набор полей `Response` получаем даром. `Request.uri` наблюдаем после редиректов (буфер приходит извне в `receiveHead(redirect_buffer)`) — это источник `Response.final_url`.

**Готовое в `std`, что сейчас не используется:**
- `initDefaultProxies(arena, environ_map)` (`:1322`) — разбор `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`. Не вызывается, поэтому сейчас не работает даже env-proxy.
- `basic_authorization` (`:1376`) — кодировщик Basic-auth из `Uri`.
- `readerDecompressing` — gzip / deflate / zstd. `.compress` не поддержан, brotli отсутствует.
- `std.json.Stringify` для marshal, `parseFromSlice(T, …)` → `Parsed(T)` для unmarshal.

**Что не подходит.** `Client.fetch()` (`:1801`) — одноразовый хелпер без доступа к заголовкам ответа и телу целиком; нужен полный контроль через `request()`.

**Тесты.** `std.net` больше нет. Схема: `std.Io.net.IpAddress.listen(&addr, io, opts)` → `Server`, `server.accept(io)` → `Stream`, дальше `std.http.Server.init(reader, writer)`.

---

## 8. Известные дефекты текущего кода

Всё это чинится в фазе 0.

| Место | Проблема |
|---|---|
| [src/client.zig:71-72](src/client.zig#L71-L72) | Утечка `value_dup`, если `header_list.append` вернёт ошибку: `errdefer` покрывает только `name_dup` |
| [src/client.zig:36](src/client.zig#L36) | Склейка URL через `allocPrint` без нормализации: `base_url = ".../api/"` + `path = "/users"` → `//users` |
| [src/client.zig:24](src/client.zig#L24) | `base_url` не дублируется — живёт по ссылке на память вызывающего |
| [src/client.zig:32](src/client.zig#L32) | Inferred error set утекает в публичный API |
| [src/client.zig:18](src/client.zig#L18) | Рудиментарный алиас `GetOptions` |
| [src/client.zig:23](src/client.zig#L23) | Не компилируется на 0.16: отсутствует обязательное поле `io` |
| [src/client_test.zig:35-36](src/client_test.zig#L35-L36) | Не компилируется на 0.16: `std.net` переехал в `std.Io.net` |
| `build.zig.zon` | `.version = "0.1.0"` при git-теге `0.2.1`; `.paths` не включает `LICENSE` и `README.md` |
| `build.zig` | Модуль `zio` создаётся без `.optimize`; `src/main.zig` (демо на httpbin.org) компилируется как тест-таргет, не имея тестов |
| `README.md` | Декларирует `Zig >= 0.15.2` |

---

## 9. Стратегия верификации

- `zig build test` зелёный на Zig 0.16 — базовый инвариант каждой фазы.
- **Юнит-тесты без сети** на каждый чистый модуль:
  - `url.zig` — join, path params, кодирование query, все варианты `ListFormat`;
  - `headers.zig` — case-insensitive, merge / override;
  - `cookie/parse.zig` — `Set-Cookie` с domain / path / expires / secure;
  - `body/multipart.zig` — побайтовая проверка тела с фиксированным boundary;
  - `retry.zig` — backoff, jitter, разбор `Retry-After`.
- **Интеграционные тесты** против loopback `std.http.Server` в отдельном потоке — расширить существующий паттерн из [src/client_test.zig](src/client_test.zig): редиректы, gzip, chunked, 100-continue, таймауты (сервер, который не отвечает), `Set-Cookie`, multipart-эхо.
- Все тесты на `std.testing.allocator` — проверка утечек включена по умолчанию.
- **Сетевые тесты** (httpbin.org) — только под флагом `-Dnetwork=true`, по умолчанию выключены, чтобы CI не зависел от внешнего сервиса.
- После фазы 8 — тесты бизнес-логики (retry, interceptors, cookies) на mock-адаптере, полностью без сокетов.
- `src/main.zig` превращается в набор примеров в `examples/` и перестаёт быть тест-таргетом.

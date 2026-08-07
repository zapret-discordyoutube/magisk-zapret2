# Upstream zapret2 payload

Эта папка — единственная точка интеграции с `bol-van/zapret2`.

`fetch-release.sh` на каждой CI-сборке проверяет последний стабильный релиз в
нашем репозитории `zapretdiscordyoutube/zapret2-upstream` на Forgejo, скачивает
официальный `zapret2-v*.tar.gz`, сверяет его с закреплённой SHA-256 из
`pinned-release.json` и отдельно проверяет Android-бинарники по upstream-файлу
`sha256sum.txt`.

`reviewed-release.txt` фиксирует релиз, по которому проверены поддерживаемые
опции и L7-протоколы безопасного TXT-компилятора. Скрипт всё равно запрашивает
latest stable, но останавливает сборку, если upstream уже выпустил новую версию:
сначала нужно просмотреть изменение грамматики, обновить тесты и только затем
сдвинуть эту отметку. Так новый бинарник не расходится молча с валидатором.

Из release-архива берутся только:

- `binaries/android-arm64/nfqws2` → `arm64-v8a`;
- `binaries/android-arm/nfqws2` → `armeabi-v7a`;
- Lua-файлы из `lua-files.txt`.

Все шесть официальных Lua-файлов `bol-van/zapret2` перечислены в `lua-files.txt`,
не хранятся в этом репозитории и загружаются заново при каждой CI-сборке.

Собственные Lua-файлы проекта автоматически не заменяются. Это
`custom_funcs.lua`, `zapret-multishake.lua`, `zapret-16kb.lua`,
`zapret-wgobfs.lua`, `zapret-custom.lua` и `init_vars.lua`.

Actions-артефакты по ссылкам вида `/actions/runs/.../artifacts/...` намеренно не
используются: они временные и требуют токен для скачивания из другого репозитория.
Публичный Forgejo Release содержит те же ARM/ARM64-сборки и согласованный
с ними Lua-код. Артефакты `android-x86` и `android-x86_64` для этого Magisk-модуля
не подходят.

Локальная проверка (Linux):

```sh
bash upstream/fetch-release.sh ./upstream-payload
```

Каталог назначения должен отсутствовать или быть пустым.

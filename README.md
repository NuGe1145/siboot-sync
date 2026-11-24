# siboot-sync

Mirror of [FrizzleM/siboot](https://github.com/FrizzleM/siboot) (MIT) to Gitee, checked hourly.

- `sync.py` — pulls upstream `install.sh` + `siboot-aarch64`, verifies the SHA-256 the script pins, then publishes both to Gitee.
- `.github/workflows/sync-to-gitee.yml` — hourly cron (`7 * * * *`).

No iOS IPA is mirrored here. Not affiliated with the upstream author.

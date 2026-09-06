# Non-Interactive GPG Commit Signing

Signing git commits with a **passworded** GPG key without an interactive tty —
and without relying on the passphrase being already cached by `gpg-agent`.

This is useful for automation (CI, scripts, agent workflows) where no human is
present to unlock the key.

Both approaches below keep the GPG key passphrase-protected on disk. The
passphrase must live *somewhere* readable by the process at run time — a
secrets manager (`pass`, OS keyring, `gpg` itself, a vault) feeding the
workflow at start is the most defensible pattern.

---

## Option 1 — `gpg-preset-passphrase` (preload the agent cache)

Keeps the key passphrase-protected on disk; only the passphrase is transient
in the agent for the session. Preferred for session-scoped automation.

### 1. Enable the preset

Edit `~/.gnupg/gpg-agent.conf`:

```text
allow-preset-passphrase
```

Restart the agent so the change takes effect:

```bash
gpgconf --kill gpg-agent
```

### 2. Resolve the keygrip of your signing key

```bash
KEYGRIP=$(gpg --list-secret-keys --with-keygrip | awk '/Keygrip/{print $3; exit}')
```

### 3. Preset the passphrase non-interactively

Feed the passphrase from your secret source (env var, file, secrets manager).
Example using an env var:

```bash
printf '%s' "$GPG_PASSPHRASE" \
  | /usr/lib/gnupg2/gpg-preset-passphrase --preset "$KEYGRIP"
```

> Path varies by distro: `/usr/lib/gnupg2/gpg-preset-passphrase` (Debian/Ubuntu),
> `/usr/libexec/gpg-preset-passphrase` (RHEL/Fedora/Arch).

### 4. Sign normally

```bash
git commit -S -m "..."
```

The agent already holds the passphrase, so no prompt appears.

---

## Option 2 — Loopback pinentry (bypass the agent per call)

Bypasses the agent entirely; `gpg` reads the passphrase directly from a file
or fd on each invocation. Requires a plaintext passphrase file readable by
the process.

### 1. Enable loopback pinentry

Edit `~/.gnupg/gpg-agent.conf`:

```text
allow-loopback-pinentry
```

Restart the agent:

```bash
gpgconf --kill gpg-agent
```

### 2. Store the passphrase in a protected file

```bash
# prefer a tmpfs / secret-manager-fed location; lock down permissions
install -m 0400 /dev/stdin /run/secrets/gpg-pass <<'EOF'
YOUR_PASSPHRASE
EOF
```

### 3. Point git at a wrapper script

```bash
git config --global gpg.program /usr/local/bin/gpg-wrapper
```

`/usr/local/bin/gpg-wrapper`:

```bash
#!/bin/sh
exec /usr/bin/gpg --pinentry-mode loopback --passphrase-file /run/secrets/gpg-pass "$@"
```

Make it executable:

```bash
chmod +x /usr/local/bin/gpg-wrapper
```

Now `git commit -S` signs without prompting.

---

## Trade-offs

| Approach | Key on disk | Passphrase location | Best for |
| --- | --- | --- | --- |
| `gpg-preset-passphrase` | Passphrase-protected | Transient in agent (session) | Session-scoped automation |
| Loopback pinentry | Passphrase-protected | Plaintext file (protected) | Fully stateless per-call signing |

## Security notes

- Never commit the passphrase file. Keep it on `tmpfs`, in a runtime secret
  mount, or retrieved on demand from a secrets manager.
- Restrict passphrase file permissions to `0400` and own it by the signing user.
- For CI, prefer injecting the passphrase via the runner's secret store into an
  env var consumed by Option 1's preset step, rather than a persistent file.

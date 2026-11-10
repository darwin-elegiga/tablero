# Tablero

Tablero de notas adhesivas para macOS: columnas *Por hacer / En curso / QA / Hecho*, proyectos con color, papelera y un recordatorio diario. Funciona en local: las notas viven en `todos.json`, en tu Mac, y nunca se suben a ningún sitio.

- **App nativa** (`notifier.swift`): ventana propia, sin servidor. La compila `build-notifier.sh`.
- **Versión navegador** (`server.py`): `python3 server.py` y abre http://localhost:8765. Solo escucha en tu Mac.
- **Nombre**: haz clic en el título para ponerle el que quieras (se guarda en `config.json`, local).

## Este repo: público, pero solo lo escribe su autor

Puedes leerlo, descargarlo y forkearlo, pero **solo su autor puede subir cambios**. Además, **todos los commits nuevos van firmados** con la clave SSH del autor (darwin-elegiga). Su clave pública está en [`signers/darwin-elegiga.allowed`](signers/darwin-elegiga.allowed).

Compruébalo tú mismo después de clonar:

```bash
git -c gpg.ssh.program=ssh-keygen -c gpg.ssh.allowedSignersFile=signers/darwin-elegiga.allowed \
  log --show-signature -3
```

Cada commit firmado muestra `Good "git" signature for darwin-elegiga`.

Los commits más antiguos, de antes de activar la firma, no la llevan.

## Por qué importa la firma

La app **se actualiza sola** desde el repo git del que la clonaste: trae los cambios, recarga la página o se recompila y reinicia. Eso significa que ejecuta en tu Mac el código que llegue del remoto. Para que nadie pueda colarte código (aunque entre en la cuenta de GitHub), **la app solo aplica commits firmados por una clave en la que tú confías**. La lista de claves de confianza está en `.git/info/allowed_signers`: es local, nunca se sube, y la crea `setup.sh`. Si falta, o si llega un commit sin una firma válida, la app no actualiza nada y te avisa.

## Usarlo tú: haz tu fork y firma con tu clave

Lo recomendado es tener **tu propio fork** y que tu app solo confíe en **tu** firma:

1. Haz un fork en GitHub y clónalo:
   ```bash
   git clone https://github.com/TU_USUARIO/tablero.git ~/tablero && cd ~/tablero
   ```
2. Configura tu identidad y tu firma (necesitas una clave SSH; si no tienes: `ssh-keygen -t ed25519`):
   ```bash
   git config user.email tu@correo
   ./setup.sh ~/.ssh/id_ed25519.pub
   ```
3. Compila e instala la app en `~/Applications`:
   ```bash
   ./build-notifier.sh
   ```
4. Cambia `BUNDLE_ID` en `build-notifier.sh` y `daily-reminder.sh` por uno tuyo (por ejemplo `io.github.TU_USUARIO.tablero`) para que tu app no se confunda con la del autor.

A partir de ahí, tus commits salen firmados y tu app solo se actualiza con ellos. Para traer novedades del repo original, revísalas y fusiónalas tú en tu fork (`git fetch upstream && git merge upstream/main`): el merge lo firmas tú.

**Alternativa — seguir directamente el repo original:** si prefieres que tu app se actualice con los commits del autor sin pasar por un fork, clona este repo y ejecuta `./setup.sh ~/.ssh/tu_clave.pub --trust-upstream`. Así confías también en la clave del autor. Hazlo solo si confías en él: su código se ejecutará en tu Mac.

## Seguridad al subir cambios

`setup.sh` activa los hooks de `githooks/`. Antes de cada commit y de cada push bloquean:

- Datos personales y archivos locales: `todos.json`, copias de seguridad, `config.json`, logs, claves.
- Secretos: claves privadas, tokens y claves de API (también con [gitleaks](https://github.com/gitleaks/gitleaks), si está instalado).
- Correos, rutas absolutas con tu usuario e IPs.
- Palabras de tu lista privada `.git/info/check-safe-denylist` (una por línea; nunca se sube).
- Commits sin firma o con otra identidad.
- Cambios que quiten las protecciones del servidor (solo localhost, control de `Host` y `Origin`) o de la página.

## Contribuir

No se aceptan pushes de terceros. Si encuentras un fallo o tienes una idea, abre un *issue*. Si el autor incorpora un cambio, lo hará con un commit firmado por él.

# Versiona

**Tu archivo, sin complicaciones. El poder de Git, sin que se note.**

Versiona convierte un repositorio privado de GitHub en un gestor documental sencillo para entornos administrativos: sube ficheros, organízalos en carpetas y consulta su historial de versiones completo, todo desde una interfaz pensada para gente que no ha usado Git en su vida.

Nada de commits, ramas ni terminal. Solo carpetas, ficheros y un motivo de cambio en lenguaje corriente — Git se queda trabajando por debajo, sin que el usuario tenga que saber que está ahí.

## Qué resuelve

Equipos administrativos (tesorería, facturación, contratos...) suelen depender de carpetas compartidas frágiles o de herramientas de control de versiones demasiado técnicas para el día a día. Versiona da lo mejor de ambos mundos:

- **Historial real de cada fichero** — cada subida queda registrada; nada se sobrescribe ni se pierde.
- **Flujo de revisión y aprobación** — los cambios entran en un espacio "pendiente de validación" y no se dan por buenos hasta que alguien los aprueba, con vista de tablero Kanban para verlo de un vistazo.
- **Cero infraestructura propia** — no hay servidor ni base de datos que mantener: cada usuario guarda sus datos en su propio repositorio privado de GitHub.
- **Sesión persistente** — el token de acceso se guarda de forma segura en el llavero del sistema (Keychain / KeyStore), así que no hay que volver a conectar la cuenta cada vez que se abre la app.
- **Varios espacios de trabajo** — cambia entre distintos repositorios ("Tesorería", "Facturas", "Contratos"...) desde un simple menú, o crea y elimina repositorios sin salir de la app.

## Cómo funciona

Al conectar tu cuenta de GitHub (mediante el flujo de dispositivo OAuth, sin backend propio ni contraseñas que gestionar), Versiona crea automáticamente un repositorio privado donde vivirán tus ficheros. Cada cambio se escribe primero en una rama de revisión; aprobarlo lo fusiona sobre la rama principal con un commit real, así que el historial de Git subyacente siempre queda intacto y consultable.

## Stack técnico

- **Flutter** (macOS, Windows, iOS, Android, Web) con Material 3
- [`provider`](https://pub.dev/packages/provider) para la gestión de estado
- [`github`](https://pub.dev/packages/github) para hablar con la API de GitHub
- [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) para la persistencia segura de la sesión

## Descargas

Cada push a `main` compila automáticamente la app y publica los binarios en la release [`build-latest`](https://github.com/Mariaisa9613/versiona/releases/tag/build-latest): siempre apunta a la última versión funcional, para macOS y Windows.

## Puesta en marcha

```bash
flutter pub get
flutter run
```

Para conectar cuentas reales de GitHub hace falta configurar tu propia OAuth App con Device Flow habilitado — las instrucciones completas están en [`lib/config/github_config.dart`](lib/config/github_config.dart). También existe un modo demo con un token compartido para probar la app sin ese paso.

### Ejecutar en Chrome con acceso a GitHub

En web, Versiona usa el flujo OAuth web con PKCE. El intercambio final del
código necesita el pequeño proxy incluido en `tool/oauth_proxy.dart`, porque
el `client secret` nunca debe incluirse dentro de JavaScript.

1. En la OAuth App de GitHub usada por Versiona, añade como **Authorization
   callback URL** `http://localhost:8080/` y genera un **Client secret**.
2. Abre un terminal, define el secreto solo para esa sesión y arranca el proxy:

   ```bash
   export OAUTH_CLIENT_SECRET='TU_SECRETO_DE_GITHUB'
   dart run tool/oauth_proxy.dart
   ```

3. En otro terminal, arranca Flutter con un puerto fijo y la URL del proxy:

   ```bash
   flutter run -d chrome --web-port 8080 \
     --dart-define=OAUTH_PROXY_URL=http://localhost:8787/oauth/token
   ```

El secreto es una credencial privada: no debe pegarse en
`lib/config/github_config.dart`, subirse a Git ni pasarse mediante
`--dart-define`.

### Publicación automática gratuita

El repositorio incluye dos workflows que se ejecutan con cada `push` a `main`:

- `.github/workflows/pages.yml` compila Flutter y publica la aplicación en
  `https://versiona.site/` mediante GitHub Pages.
- `.github/workflows/oauth-worker.yml` publica el proxy OAuth gratuito incluido
  en `oauth-worker/` mediante Cloudflare Workers.

Configuración inicial, una sola vez:

1. En **GitHub → repositorio Versiona → Settings → Pages**, selecciona
   **GitHub Actions** como origen.
2. Crea una cuenta gratuita en Cloudflare y obtén un API Token con permiso
   **Workers Scripts: Edit** y el Account ID.
3. En **GitHub → Settings → Secrets and variables → Actions → Secrets**, crea:
   `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` y
   `OAUTH_CLIENT_SECRET`.
4. Ejecuta manualmente el workflow **Publicar proxy OAuth**. Cloudflare le dará
   una URL parecida a `https://versiona-oauth.<subdominio>.workers.dev`.
5. En la pestaña **Variables** de Actions, crea `OAUTH_PROXY_URL` con la URL
   anterior seguida de `/oauth/token`.
6. En la OAuth App de GitHub configura como callback exacto
   `https://versiona.site/`.
7. Ejecuta **Publicar Versiona Web**, o haz un nuevo `push` a `main`.

Después de esta configuración, los siguientes despliegues son automáticos. El
Client secret permanece cifrado en GitHub Actions y como secreto del Worker; no
forma parte de la aplicación web ni del historial Git.

## Licencia

[MIT](LICENSE)

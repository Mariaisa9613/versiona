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

## Puesta en marcha

```bash
flutter pub get
flutter run
```

Para conectar cuentas reales de GitHub hace falta configurar tu propia OAuth App con Device Flow habilitado — las instrucciones completas están en [`lib/config/github_config.dart`](lib/config/github_config.dart). También existe un modo demo con un token compartido para probar la app sin ese paso.

## Licencia

[MIT](LICENSE)

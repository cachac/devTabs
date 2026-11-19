# devTabs

Tiling para macOS con stacks de pestañas al estilo de Pop!_OS y modo accordion.

- Acomoda las ventanas del Space visible de cada monitor. No crea workspaces propios y nunca saca ventanas fuera de la pantalla.
- Cada ventana nueva parte en dos a la que tiene el foco: a lo ancho si es más ancha que alta, si no a lo alto.
- Un stack junta varias ventanas en el mismo hueco, con una barra de pestañas arriba. Las de atrás quedan debajo de la activa.
- En accordion, las ventanas de atrás asoman con un margen a los costados de la activa (30 px al empezar). Arrastrando con el mouse el borde de la ventana activa se ajusta cuánto asoman; la activa siempre deja al menos 240 px a la vista.

## Compilar y abrir

```sh
scripts/build-app.sh
open build/devTabs.app
```

La primera vez pide el permiso de Accesibilidad (Ajustes del Sistema → Privacidad y seguridad → Accesibilidad). La app se firma con el certificado «Apple Development» que haya en el llavero, así el permiso sigue valiendo en las builds siguientes.

No lo corras junto con otro gestor de ventanas (Amethyst, AeroSpace, OmniWM, Rift).

Para salir: el ícono de la barra de menú → «Salir de devTabs».

## Atajos

Todos van con Control + Comando (⌃⌘).

| Atajo | Qué hace |
|---|---|
| `⌃⌘ ← ↓ ↑ →` | pasa el foco a la ventana de ese lado (también salta de monitor). En un stack, `←` y `→` cambian de pestaña; desde la primera o la última, el foco sigue a la ventana vecina |
| `⌃⌘⇧ ← ↓ ↑ →` | mueve la ventana: sale de su stack, entra al stack vecino o se intercambia con la ventana vecina |
| `⌃⌘S` | junta en un stack todas las ventanas del monitor; si ya están juntas, cada una vuelve a su lugar |
| `⌃⌘A` | pasa el stack de pestañas a accordion y viceversa |
| `⌃⌘O` | cambia la orientación de la división del hueco |
| `⌃⌘+` / `⌃⌘-` | agranda o achica el hueco |
| `⌃⌘G` | deja la ventana flotando, o la vuelve a acomodar |
| `⌃⌘Y` | prende o apaga el tiling en el monitor de la ventana enfocada |

Las pestañas también se eligen con un clic. Si el foco llega a una ventana de atrás (⌘Tab), esa pasa a ser la activa.

`+` y `-` se buscan por el carácter que escribe la tecla en la distribución de teclado activa al abrir la app. Si cambiás de distribución, volvé a abrir devTabs.

## Pruebas

```sh
swift test
```

Prueban el árbol y el layout (`Sources/DevTabsCore`), sin tocar ventanas reales.

## Límites de esta versión

- Sin archivo de configuración: márgenes (8 px), alto de la barra (28 px) y franja del accordion (30 px) están en `WindowManager.swift`.
- Una app ocultada con ⌘H o una ventana minimizada sale del árbol; al volver entra como ventana nueva.
- Si arrastrás o redimensionás una ventana acomodada (fuera del borde de un accordion), vuelve a su lugar al soltar el mouse. Si la soltás en otro monitor, pasa a acomodarse ahí.
- El ancho ajustado de un accordion vale mientras devTabs siga abierto; al volver a abrirlo empieza en 30 px.
- Sin animaciones ni arrastre de pestañas con el mouse.
- Log: `~/Library/Logs/devTabs.log`.

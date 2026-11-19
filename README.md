# devTabs

Tiling para macOS con pestañas al estilo de Pop!_OS y modo acordeón.

## Atajos

| Atajo | Acción |
|---|---|
| `Control + Comando + ← ↓ ↑ →` | Mover el foco. Dentro de un stack, `←` `→` cambian de pestaña |
| `Control + Comando + Shift + ← ↓ ↑ →` | Mover la ventana: intercambiarla con la vecina o meterla en el stack vecino. Dentro de un stack, `←` `→` corren la pestaña y desde la primera o la última la sacan |
| `Control + Comando + S` | Juntar todas las ventanas del workspace en un stack, o separarlas |
| `Control + Comando + A` | Pasar el stack de pestañas a acordeón, o volver |
| `Control + Comando + O` | Cambiar la orientación de la división |
| `Control + Comando + +` / `-` | Agrandar o achicar el hueco |
| `Control + Comando + G` | Hacer flotar la ventana (centrada y adelante), o devolverla a su lugar. Las de tamaño fijo, como Ajustes del Sistema, flotan solas |
| `Control + Comando + Y` | Prender o apagar el tiling del workspace actual |
| `Control + Comando + Z` | Zoom temporal: la ventana ocupa todo el monitor; otra vez, vuelve a su lugar |

Un punto naranja en una pestaña de atrás avisa que su ventana cambió de título (por ejemplo, terminó una tarea) desde la última vez que la miraste.

## Con el mouse

- **Clic en una pestaña**: la activa.
- **Arrastrar una pestaña sobre otra**: la lleva a esa posición.
- **Arrastrar el borde entre dos ventanas**: cambia sus tamaños.
- **Arrastrar el borde de la ventana de adelante en un acordeón**: ajusta cuánto se ve de las de atrás. El ancho elegido queda para los próximos acordeones.
- **Soltar una ventana en otro monitor**: pasa a acomodarse ahí.

## Al reabrir

Vuelven los stacks, los acordeones, los tamaños y las ventanas flotantes de todo lo que siga abierto.

## Menú

En el ícono de la barra de menú: separación entre ventanas, reacomodar y salir.

## Instalar

```sh
scripts/build-app.sh
open build/devTabs.app
```

La primera vez pide el permiso de Accesibilidad. No usarlo junto con otro gestor de ventanas.

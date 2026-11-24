# Identidad visual de TONAMOX

Selección confirmada el 20 de octubre de 2026. Marca: **TONAMOX**, sin sufijos ni subtítulo. Se conserva el libro dorado y cian fusionado con tres circuitos sobre fondo azul oscuro.

| Archivo | Uso guardado |
| --- | --- |
| [tonamox-icon.png](tonamox-icon.png) | Referencia del icono sin textos, PNG de 1254 × 1254 píxeles. |
| [tonamox-brand.png](tonamox-brand.png) | Presentación con TONAMOX y muestra monocroma, sin subtítulo, PNG de 1030 × 1526 píxeles. |

Estos recursos se guardan como documentación de la selección. No están integrados en Assets.xcassets, en la web ni en el empaquetado. Las exportaciones para producción y su validación quedan pendientes hasta que Claude termine, conforme al [plan de renombrado](../../../RENAMING-PLAN.md).

## Procedencia y edición

Se utilizó la herramienta integrada imagegen sobre la presentación seleccionada por el usuario, sin cambiar de dirección visual. La imagen de origen de la conversación es `exec-f46923d7-ecb6-489c-9f18-103b3157fb31.png`; los resultados se copiaron al repositorio conservando los originales generados. Son imágenes rasterizadas derivadas de la selección, no una fuente vectorial ni una extracción con identidad de píxeles garantizada.

## Prompts utilizados

Presentación sin subtítulo:

```text
Edit this selected TONAMOX branding image. Remove the subtitle beneath TONAMOX completely, leaving clean blank white background in its former area. Keep only TONAMOX as text. Keep all other content and the overall layout unchanged: the exact large navy rounded-square icon with open gold and cyan book and three circuit terminals, its shading and geometry, the centered bold TONAMOX heading, and the small monochrome symbol at the bottom. Do not redesign the icon, do not add plus signs or any new text. Preserve the existing proportions, margins and portrait layout. This edit must simply remove the subtitle without replacing it with anything.
```

Icono independiente:

```text
Precise extraction of the selected app icon from this reference branding sheet. Output a square image containing ONLY the large top app icon: the navy rounded square with gold left book pages, cyan right pages, and THREE gold-to-cyan circuit traces ending in three circular nodes. Preserve its existing exact design, geometry, materials, colors, gradients, and lighting. Center this selected icon with a small even white margin in a square canvas. Remove ALL typography and the small monochrome symbol; no text, no TONAMOX word, no subtitle, no plus signs. Do not redesign, simplify, invent details or change the number of circuit terminals. This is the selected existing icon exported on its own, not a new variant.
```

## Icono plano (19 de noviembre de 2026)

El icono se redibujó en plano, con el mismo motivo y sin degradados, brillos ni sombras. La fuente vectorial es [app-icon-flat.svg](../app-icon-flat.svg) (variante A). `tonamox-icon.png` y `docs/media/logo.png` son ahora esa variante A, con esquinas redondeadas y transparentes; `tonamox-brand.png` sigue mostrando el diseño anterior. Las apps de ejemplo usan un conjunto de iconos propio cada una en `Sources/TonamoxExample/Common/Assets.xcassets`: `AppIcon` (TonamoxExample, variante A), `AppIconLibrary` (azul marino), `AppIconChat` (solo azules), `AppIconImage` (fondo claro) y `AppIconTerminal` (negro grafito). Las cuatro variantes de color se comparan en [app-icon-flat-variantes.png](../app-icon-flat-variantes.png).

# Probar el extractor

En macOS, con las herramientas de línea de comandos de Xcode instaladas:

```sh
./Banco/muestras.sh
./Banco/probar.sh
```

El primer guion lee el arte de las apps de `/Applications` y `~/Applications`, incluido
el primer nivel de carpetas de fabricantes. Guarda `muestras/<nombre-resumen>/original.png`.
No modifica las apps. También acepta carpetas de apps como argumentos.

El segundo compila el extractor actual y genera las hojas comparativas y `log.tsv` en
`Banco/salida/actual`. Revisa las imágenes clara y oscura buscando restos del fondo, halos
y detalles perdidos. Se puede elegir otro extractor y una muestra:

```sh
./Banco/probar.sh Sources/Iconos 'Nombre-resumen'
```

Las muestras y los resultados contienen marcas de terceros: son locales, están ignorados
por Git y no deben publicarse.

`./Banco/seguridad.sh` prueba almacenamiento, validación y restauración sobre bundles
ficticios en una carpeta temporal, sin usar los datos reales de Iconos.

---
title: ENDAVA
date: 2022-08-01
draft: false

job_title: Desarrollador Senior
start_date: Agosto 2022
end_date: Diciembre 2024
---

### Motor Matemático (Junio 2024 - Diciembre 2024)

Se desarrolló un motor matemático para el dimensionamiento de cotizaciones y
análisis de inversiones en préstamos inmobiliarios. Mis principales
contribuciones fueron:

- Crear generation de casos de pruebas automáticas a través del uso del
archivos JSON que contienen los diferentes escenarios de pruebas.

- Búsqueda binaria multi objetivo o de espacio de optimización para encontrar
la máxima cantidad de dinero que se puede prestar y para encontrar los mínimos
ingresos operativos netos para obtener la cantidad de dinero deseada.

Versión Open Source del paquete cálculador de préstamos en [Go][1]

### Nubes de Puntos (Agosto 2022 - Mayo 2024)

Se desarrolló y se hizo mantenimiento de un programa de escritorio en PyQt,
con VTK para el renderizado 3D, para anotar nubes de puntos a través de una
interfaz gráfica. Mis principales contribuciones al proyecto fueron:

- Liderar la parte de Python en la migración de la aplicación de Python 3.2 a
Python 3.10, mientras otra persona del equipo lideró las migraciones de PyQt6
y de VTK, lo que además implicó rehacer el sistema de eventos sobre mensajes y
señales. Una refactorización mayor, resolviendo los cambios de comportamiento
y las restricciones de dependencias de una base compilada y con mucha interfaz
gráfica.

- Crear y liderar la implementación de una arquitectura orientada a eventos
para funcionalidades pesadas de cálculo, donde desvié la carga de las funciones
a otros núcleos de la computadora mediante el uso de procesamiento múltiple y
otras optimizaciones en la creación de objetos para disminuir el impacto en el
consumo de RAM, lo que duplicó la velocidad del software y redujo su uso de RAM
en un 40%.

- Automatizar la creación de planos y otros dibujos técnicos a partir de la
nube de puntos, mediante el uso de un servidor local que manejaba las
actualizaciones o cambios de las formas anotadas dentro de la nube de puntos.

- Crear una fachada para el SDK de BOX Cloud, para manejar de forma segura el
multihilo y simplificar la funcionalidad de nuestras actualizaciones y cargas
de archivos.

[1]: https://github.com/jacobitosuperstar/go-cre-loan-calculations

# Plan de trabajo para convertir Trefil OS en el sistema empresarial principal

**Fecha base:** 18 de noviembre de 2026  
**Objetivo:** dejar Trefil OS operando con usuarios reales y reemplazar Alegra como fuente principal de ventas, compras, inventarios, cartera, caja, contabilidad y reportes de Trefil Electric.

## 1. Qué significa “100 %”

La plataforma se considerará lista para reemplazar Alegra únicamente cuando cumpla simultáneamente estas condiciones:

1. Todos los datos operativos se guardan en la base institucional; `localStorage` no es fuente oficial.
2. Cada persona entra con una cuenta individual, MFA cuando corresponda y permisos efectivos en servidor.
3. Ventas, recaudos, compras, inventario, producción, caja, bancos, cartera y contabilidad forman un recorrido único y trazable.
4. Las facturas, notas y demás documentos fiscales usados por la empresa son aceptados por la DIAN mediante el modo de operación elegido.
5. Un comprobante de recaudo no paga facturas por sí solo: tesorería verifica cuentas receptoras, importe total y distribución.
6. La contabilidad cuadra por partida doble; no existen saldos editables ni operaciones borrables.
7. Los datos de Alegra están migrados o archivados, conciliados y aprobados por gerencia y contabilidad.
8. Existe respaldo automático, restauración ensayada, monitoreo, soporte y un procedimiento de contingencia.
9. Los responsables de cada área completan dos cierres paralelos sin diferencias materiales.
10. Alegra queda únicamente como consulta histórica durante el período de retención acordado.

Publicar una pantalla, aprobar pruebas automáticas o tener un enlace de Vercel no satisface por sí solo esta definición.

## 2. Estado actual y brecha principal

| Área | Situación actual | Para operación real |
| --- | --- | --- |
| Interfaz y reglas | Caja, Inventarios, Deudas, Ventas, Agenda, Informes, Equipo, recaudos y abastecimiento están construidos en distintos grados. | Consolidar recorridos, estados, errores y permisos de cada módulo. |
| Datos operativos | La mayoría de los módulos usan una instantánea local del navegador. | Adaptador completo a Supabase, transacciones atómicas y concurrencia multiusuario. |
| Base institucional | Existen migraciones financieras, RLS, Storage privado y estructuras de Equipo/MCP. | Completar esquemas de todos los módulos, probarlos con usuarios reales y conectar la aplicación. |
| Usuarios | Hay flujos de Equipo, cédula, contraseña, roles y permisos. | Aprovisionamiento real, recuperación, MFA, revocación, sesiones y administración desde la plataforma. |
| Facturación | Ventas conserva documentos comerciales locales. | Facturación electrónica DIAN, notas, numeración, contingencia, correo y estado legal. |
| Contabilidad | Existe un núcleo de doble entrada para tesorería. | Plan de cuentas completo, causación, impuestos, centros, cierres y estados financieros. |
| Alegra | Existe una estructura inicial de importación de contactos, productos y facturas. | Exportación completa, mapeo, carga repetible, conciliación, saldos iniciales y corte final. |
| Continuidad | Hay herramientas de respaldo y restauración. | Ejecución real diaria, copia externa, alertas y restauración cronometrada. |

La prioridad cero es sustituir la persistencia local. No se deben cargar operaciones reales en los módulos actuales hasta que el recorrido institucional esté conectado y probado.

## 3. Equipo mínimo y responsabilidades

| Responsabilidad | Propietario recomendado |
| --- | --- |
| Prioridad, políticas, excepciones y aceptación final | Federico Velásquez, dueño del producto |
| Plan de cuentas, impuestos, saldos, cierres y DIAN | Contador o asesor tributario de la empresa |
| Reglas de ventas, precios, cartera y devoluciones | Responsable comercial |
| Producción, lotes, consumos, desperdicio y liberación | Responsable de Producción |
| Recepciones, existencias, conteos y despachos | Responsable de Bodega/Inventarios |
| Bancos, caja, recaudos, pagos y conciliación | Responsable de Tesorería |
| Arquitectura, desarrollo, pruebas y despliegue | Equipo técnico de Trefil OS |
| Ensayos de uso y aceptación | Un usuario piloto por área |

Ninguna persona debe aprobar sus propias operaciones sensibles. El responsable funcional define la regla; el equipo técnico la implementa; un usuario distinto la valida.

## 4. Fases de implementación

### Fase 0 — Inventario funcional de Alegra y gobierno (semana 1)

**Trabajo**

- Enumerar exactamente qué usa Trefil Electric en Alegra: facturación, notas, remisiones, compras, inventario, bancos, cartera, cuentas por pagar, reportes, contabilidad, POS y nómina si aplican.
- Congelar el diccionario empresarial: sedes, bodegas, cuentas bancarias, medios de pago, listas de precios, impuestos, retenciones, unidades, centros de costo y responsables.
- Aprobar matriz de roles y permisos por acción, no solo por pantalla.
- Definir política de aprobaciones, montos, cierres, correcciones y segregación de funciones.
- Elegir la vía DIAN: proveedor tecnológico habilitado, software propio o solución gratuita. Para reducir riesgo y tiempo, la ruta recomendada es integrar un proveedor tecnológico habilitado y conservar Trefil OS como sistema de operación.
- Determinar si nómina electrónica y documento soporte harán parte del primer corte o de una fase posterior sin bloquear la contabilidad principal.

**Entregables y salida**

- Matriz “Alegra actual → Trefil OS”.
- Catálogo de procesos y responsables firmado.
- Matriz de permisos aprobada.
- Decisión documentada sobre DIAN.
- Inventario de fuentes y período histórico que será migrado.

### Fase 1 — Núcleo institucional y seguridad (semanas 2 a 4)

**Trabajo**

- Convertir la aplicación estática en una aplicación institucional con backend controlado.
- Crear el adaptador Supabase para lectura y escritura de cada operación.
- Eliminar `localStorage` como fuente oficial; conservarlo solo para preferencias no sensibles o borradores explícitos.
- Aplicar identidad individual, cédula como identificador de ingreso, recuperación segura y MFA para administradores/aprobadores.
- Hacer que permisos y roles se validen en base de datos, Edge Functions o servidor; ocultar botones no basta.
- Integrar Storage privado para comprobantes, facturas, actas, fotos y soportes con checksum.
- Establecer auditoría inmutable, claves de idempotencia y manejo de concurrencia.
- Crear ambientes separados de desarrollo, pruebas y producción.

**Pruebas de salida**

- Dos usuarios simultáneos ven el mismo dato después de recargar y desde dispositivos distintos.
- Usuario inactivo, rol incorrecto, sede ajena y sesión AAL1 reciben denegación real.
- Repetir una solicitud no duplica dinero, factura, inventario ni recaudo.
- Un soporte privado no puede leerse sin sesión y permiso.
- Toda operación sensible conserva actor, fecha, origen y cambios.

### Fase 2 — Maestros, Equipo y administración (semanas 4 a 6)

**Trabajo**

- Administración directa de personas, cargos, áreas, sedes, roles, funciones y permisos detallados.
- Alta con contraseña temporal o enlace individual, obligación de cambio inicial y recuperación administrada.
- Eliminar/desactivar usuario sin borrar su historial; impedir eliminar al último administrador total.
- Horarios, marcación de entrada/salida, novedades, tareas del día, responsables y supervisión.
- Maestros únicos de clientes, proveedores, productos, materias primas, insumos, activos, impuestos, unidades, bodegas, cuentas y centros de costo.
- Importación controlada y detección de duplicados por identificación, SKU y referencias externas.

**Pruebas de salida**

- El administrador crea, modifica, suspende y recupera una cuenta desde Trefil OS.
- Cada permiso impide de verdad consultar o ejecutar la función no autorizada.
- Los maestros son compartidos por todos los módulos y no se duplican.

### Fase 3 — Operación integrada (semanas 6 a 11)

#### 3A. Ventas, facturación y recaudos

- Cotización → pedido → orden de producción/entrega → despacho → factura → cartera → recaudo.
- Factura electrónica, notas crédito/débito, numeración, contingencia y estado DIAN.
- Pagos parciales, anticipos, retenciones, devoluciones, garantías y vendedores.
- Un recaudo puede entrar en varias cuentas y pagar varias facturas; exige soporte, observación y verificación independiente.
- Separar claramente facturado, vencido, reportado, recibido, verificado y aplicado.

#### 3B. Inventario, producción y compras

- Materia prima e insumos entran por compra/recepción y salen por consumo de producción u otras salidas documentadas.
- Producto terminado entra únicamente al aceptar el lote producido y sale por despacho de pedidos, muestras, consumo interno, bajas, donaciones o traslados autorizados.
- Responsables por entrega de Producción, conformidad de Ventas, recepción de Bodega y liberación.
- Solicitud de compra → cotizaciones → aprobación → orden de compra → recepción → factura del proveedor → pago.
- Mínimos/máximos, punto de reorden, plazo del proveedor, compromiso abierto y promedio de consumo/gasto.
- Conteos físicos, diferencias, cuarentena, lotes, trazabilidad, desperdicios y cierres de inventario.

#### 3C. Caja, bancos, deudas y agenda

- Cuentas bancarias, cajas y pasarelas conectadas al libro; turnos solo para efectivo.
- Ingresos, egresos, traslados, anticipos, préstamos, inversiones, gastos y reversos con soporte.
- Importación/lectura de extractos, conciliación y control de duplicados.
- Cuentas por pagar, préstamos, cuotas, pagos por componentes y compromisos recurrentes.
- Agenda de vencimientos con responsables, alertas y enlaces al documento real.

**Pruebas de salida**

- Recorrido completo de venta sin doble salida de inventario ni doble recaudo.
- Recorrido completo de compra sin duplicar inventario, deuda o pago.
- Traslado conserva el total entre cuentas o bodegas.
- Cierre bloqueado ante diferencias o soportes obligatorios pendientes.
- Reversos conservan el original y crean el efecto contrario con aprobación.

### Fase 4 — Contabilidad, impuestos e informes (semanas 9 a 13)

Esta fase corre parcialmente en paralelo con la Fase 3 y requiere al contador.

**Trabajo**

- Plan Único de Cuentas utilizado por la empresa, terceros y centros de costo.
- Reglas de causación para ventas, compras, inventarios, cartera, impuestos, retenciones, nómina y activos cuando apliquen.
- Comprobantes contables, libro diario, mayor y balances por tercero y cuenta.
- Cuentas por cobrar/pagar, antigüedad, estado de resultados, balance general y flujo de efectivo.
- IVA, retenciones y reportes auxiliares requeridos por contabilidad.
- Períodos abiertos/cerrados, cierre mensual, reapertura excepcional y trazabilidad.
- Exportaciones para contador y conservación de documentos electrónicos.

**Pruebas de salida**

- Débitos y créditos siempre cuadran.
- Auxiliares concilian con cartera, proveedores, inventario, bancos y caja.
- El cierre impide modificaciones retroactivas no autorizadas.
- Los estados financieros pueden reconstruirse desde los movimientos y coinciden con el corte aprobado.

### Fase 5 — Migración de Alegra (semanas 10 a 14)

**Orden de migración**

1. Copia completa y exportaciones originales, conservadas sin modificación.
2. Contactos, productos/servicios, impuestos, listas de precios y bodegas.
3. Facturas de venta, notas, cotizaciones, remisiones y detalle por producto.
4. Facturas de proveedor, gastos, pagos y cuentas por pagar.
5. Inventario por bodega, costos y movimientos históricos disponibles.
6. Bancos, caja, cuentas por cobrar, anticipos y demás saldos abiertos.
7. Plan de cuentas, comprobantes y saldos contables aprobados.
8. Documentos adjuntos y referencias fiscales que deban conservarse.

**Método**

- Cada importación usa un lote, huella del archivo, conteos, errores por fila y posibilidad de repetir sin duplicar.
- Primero se ejecutan al menos dos simulaciones en pruebas.
- Los documentos históricos se marcan como provenientes de Alegra; no se reenvían a la DIAN ni se recrean como documentos nuevos.
- Los saldos de corte requieren acta firmada por gerencia y contabilidad.
- La migración final importa solo el diferencial posterior a la última simulación.

**Conciliaciones obligatorias**

- Número de clientes/proveedores/productos.
- Cantidad y total de ventas/compras/notas por período.
- Cartera por cliente y cuentas por pagar por proveedor.
- Existencias y valoración por producto y bodega.
- Saldos por banco/caja.
- Balance de prueba y estados financieros al corte.

La diferencia monetaria aceptable al corte debe ser **COP 0**; cualquier diferencia queda identificada y resuelta antes del cambio definitivo.

### Fase 6 — Continuidad, seguridad y operación (semanas 12 a 15)

**Trabajo**

- Respaldo cifrado diario, copia independiente, retención y alertas por ausencia/fallo.
- Restauración completa en un entorno aislado, con tiempo de recuperación medido.
- Monitoreo de errores, operaciones fallidas, documentos DIAN, respaldos y accesos inusuales.
- Protección de producción, cabeceras, límites de solicitudes y rotación de credenciales.
- Manuales por rol, mesa de ayuda, responsables de incidentes y procedimiento de contingencia.
- Política de cambios: desarrollo → pruebas → aprobación → producción.

**Pruebas de salida**

- Restauración recupera usuarios, documentos, saldos y soportes.
- Una caída durante una operación permite reintentar sin duplicarla.
- Existe responsable y tiempo objetivo para cada alerta crítica.

### Fase 7 — Piloto paralelo y reemplazo (semanas 15 a 18)

**Piloto**

- Primera semana: usuarios piloto de cada área con operaciones controladas.
- Siguientes cuatro semanas: registrar en paralelo en Alegra y Trefil OS.
- Conciliar diariamente ventas, recaudos, bancos e inventario; semanalmente cartera, proveedores y compras; mensualmente contabilidad completa.
- Ejecutar dos cierres mensuales consecutivos sin diferencias materiales ni fallos críticos abiertos.

**Corte definitivo**

1. Congelar altas nuevas en Alegra al cierre acordado.
2. Tomar copia y exportación final.
3. Cargar el diferencial y conciliar COP 0.
4. Confirmar numeración y emisión fiscal en producción.
5. Habilitar Trefil OS como único sistema de registro.
6. Conservar Alegra en modo consulta durante el período acordado; no cancelarlo hasta verificar acceso a históricos y obligaciones de conservación.
7. Mantener un plan de reversión documentado durante la primera semana.

## 5. Calendario y capacidad

La estimación base es **18 semanas** con un responsable técnico de tiempo completo, apoyo de pruebas y disponibilidad semanal de los dueños de proceso y del contador. Con una sola persona técnica y validaciones esporádicas, la proyección razonable es de **24 a 30 semanas**.

| Hito | Resultado | Semana objetivo |
| --- | --- | ---: |
| H1 | Alcance, permisos, datos y decisión DIAN aprobados | 1 |
| H2 | Persistencia multiusuario y seguridad institucional | 4 |
| H3 | Equipo y maestros operativos | 6 |
| H4 | Ventas, compras, inventario, producción y tesorería integrados | 11 |
| H5 | Contabilidad e informes conciliables | 13 |
| H6 | Migración simulada cuadrada y restauración aprobada | 15 |
| H7 | Dos cierres paralelos aprobados y corte final | 18 |

Las fechas se desplazan si faltan definiciones contables, acceso a DIAN/proveedor, exportaciones de Alegra o validación de responsables. No se recorta seguridad, conciliación ni respaldo para sostener una fecha.

## 6. Tablero semanal de control

Cada requisito tendrá uno de estos estados: planificado, en desarrollo, implementado, probado, piloto, aprobado o bloqueado.

El comité semanal revisará:

- avance por módulo y no solo por cantidad de pantallas;
- fallos críticos abiertos y tiempo de resolución;
- pruebas aprobadas en desarrollo, pruebas y producción;
- porcentaje de datos migrados y conciliados;
- usuarios entrenados y recorridos completados;
- respaldos verificados y última restauración;
- documentos DIAN aceptados/rechazados;
- diferencias de caja, bancos, inventario y contabilidad;
- decisiones pendientes, responsable y fecha límite.

## 7. Prioridad inmediata: próximas dos semanas

1. Actualizar el inventario de funciones que Trefil Electric usa hoy en Alegra.
2. Aprobar matriz de roles, permisos y segregación de funciones.
3. Aprobar plan de cuentas, impuestos, retenciones, bodegas y centros de costo.
4. Elegir e iniciar la integración DIAN.
5. Diseñar el esquema remoto faltante para Ventas, Inventarios, Producción, Compras, Agenda e Informes.
6. Implementar el adaptador Supabase y retirar `localStorage` del primer recorrido vertical.
7. Elegir como primer recorrido productivo: pedido → despacho → factura → recaudo verificado → asiento contable.
8. Crear usuarios piloto de Ventas, Bodega, Tesorería, Contabilidad y Administración.
9. Exportar de Alegra un primer paquete de prueba: contactos, ítems, facturas de venta, facturas de proveedor y reportes de saldos.
10. Ejecutar la primera importación simulada y publicar su conciliación, sin tocar todavía los datos operativos de producción.

## 8. Decisiones que no deben aplazarse

- Proveedor tecnológico DIAN o desarrollo propio.
- Alcance de nómina electrónica y documento soporte.
- Período histórico que se migrará en detalle y período que quedará como archivo.
- Responsable de aprobar saldos iniciales y cierres.
- Política de contraseñas, MFA y dispositivos autorizados.
- Retención de documentos y tiempo de consulta de Alegra.
- Montos y operaciones con doble aprobación.
- Tiempo máximo permitido sin sistema y procedimiento manual de contingencia.

## 9. Regla de salida de Alegra

No se cancela ni se deja de registrar en Alegra hasta que el comité de salida firme que:

- los datos finales conciliaron en COP 0;
- la DIAN aceptó los documentos de producción requeridos;
- los usuarios completaron sus recorridos con permisos reales;
- los dos cierres paralelos fueron aprobados;
- el respaldo y la restauración fueron comprobados;
- no quedan fallos críticos o altos sin mitigación;
- existen manual, soporte y contingencia activos.

Esta regla protege la continuidad de la empresa y convierte el reemplazo en una decisión verificable, no en una impresión visual de que la plataforma está terminada.

## 10. Referencias de planificación

- DIAN, [requerimientos para ser facturador electrónico](https://micrositios.dian.gov.co/sistema-de-facturacion-electronica/requerimientos-para-ser-facturador-electronico/): modos de operación, firma digital y set de habilitación para proveedor tecnológico o desarrollo propio.
- DIAN, [documentos que componen el Sistema de Factura Electrónica](https://www.dian.gov.co/impuestos/factura-electronica/Documents/Abece-sistema-de-factura-electronica.pdf): factura, notas y documentos soporte electrónicos.
- Alegra, [exportación de información](https://ayuda.alegra.com/int/c%C3%B3mo-es-el-proceso-para-exportar-tu-informaci%C3%B3n-desde-alegra): reportes, facturas, notas, cotizaciones, remisiones, proveedores, contactos e ítems.

Estas referencias orientan el proyecto, pero las decisiones tributarias y el alcance fiscal final deben ser aprobados por el contador o asesor tributario de Trefil Electric antes del paso a producción.

# Módulo 04 - Ventas

Implementación funcional basada en el corte aprobado del 11 de noviembre de 2026.

## Alcance implementado

- Panel comercial integrado en `#ventas`, conservando la estética de Trefil OS.
- Clientes, listas de precios versionadas desde Producción, cotizaciones, OP por categoría, facturación unificada y cartera documental.
- Categorías TFI, TFF, TFM, TFR, TFC, TFMP, TFMI, GAR y operación de vendedores externos.
- TFI exige transportadora y guía; TFM/TFMP no se facturan hasta que Producción confirme `Listo para entregar`.
- Cotizaciones mixtas se convierten en OP separadas por categoría y no reservan inventario, caja ni cartera.
- Facturar no crea recaudos. Los pagos externos permanecen reportados hasta vincularse con un ingreso real de Caja y aplicarse a facturas.
- Recaudos separa comprobante, ingreso verificado y aplicación a cartera. Un recaudo puede contener ingresos en varias cuentas; cada línea conserva valor, medio, referencia única, comprobante real y observaciones.
- Una factura puede recibir aplicaciones de varios ingresos y un mismo ingreso verificado puede distribuirse entre varias facturas del mismo cliente. La factura solo cambia a `Pagada` cuando las aplicaciones verificadas cubren todo su saldo.
- Cada ingreso se cruza con un movimiento `income` aprobado de Caja, por el mismo valor y cuenta receptora. Los traslados internos no son elegibles, un movimiento no se reutiliza y las referencias no pueden repetirse dentro de la misma cuenta.
- Vendedores externos conservan OP, aceptación de cantidades, DV, cierre semanal y factura neta después de devoluciones verificadas.
- Garantías separadas de DV y retornos TFI; Producción registra el dictamen y GAR crea una OP de valor cero sin segunda venta.
- Consulta de inventario, lotes y conteos/cierres de Producto Terminado sin habilitar ajustes desde Ventas.
- Toda anulación conserva consecutivo, motivo, historia y auditoría.

## Integraciones y límites

- Inventarios es la fuente de referencias, bodegas, existencias, lotes y conteos.
- Caja es la única fuente de cobros verificados y de reembolsos.
- El comprobante adjunto por sí solo nunca modifica cartera. Las aplicaciones múltiples exigen observación y cada verificación/aplicación deja auditoría con responsable y fecha.
- Producción es la fuente de listas de precios, procesos, tarifas y dictámenes técnicos.
- Ventas conserva una fotografía del precio en cada factura; una nueva lista no reescribe documentos finalizados.
- El despacho confirmado crea exactamente una salida en el libro local de Inventarios; facturar después no vuelve a descontar. Una DV externa solo crea el reingreso cuando el usuario verifica físicamente la devolución. Ambos procesos rechazan períodos de inventario cerrados y usan claves de origen trazables.
- La sincronización de estos libros locales con PostgreSQL institucional continúa pendiente; no se presentan los datos del navegador como registros remotos verificados.

## Pendientes no inventados

- Campos exactos de guías por transportadora y sincronización automática de seguimiento.
- Responsable físico definitivo del retorno TFI y reglas de paquetes incompletos.
- Fórmula y parámetros actuales de comisiones.
- Tratamiento de anulación cuando ya existen pagos asociados.
- Calendario técnico de semanas y formato final de PDF comerciales.
- Aspectos tributarios.

Estos puntos aparecen como configuración pendiente y no se presentan como reglas aprobadas.

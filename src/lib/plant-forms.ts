export type Area = "produccion" | "control";
export type Line = {
  ficha: string;
  cantidad: string;
  prioridad: string;
  responsable: string;
  fecha: string;
  verificado?: boolean;
  fichaTecnica?: { codigo: string; ruta: string };
};
export type Row = {
  id: string;
  series: number;
  kind: string;
  title: string;
  state: string;
  author: string;
  version: number;
  parent: string | null;
  created: string;
  data: Record<string, unknown>;
};
export type Member = {
  id: string;
  nombre: string;
  activo: boolean;
  perfil: string | null;
  permisos: string[] | null;
};
export type Snapshot = {
  persona: string;
  nombre: string;
  perfil: string;
  permisos: string[];
  opciones: string[];
  registros: Row[];
  personas: Member[];
  corte: string;
  panel: Record<string, number> | null;
  auditoria: {
    seq: number;
    actor: string;
    action: string;
    at_time: string;
    reason: string;
    target: string;
  }[];
};
export type FieldSpec = {
  key: string;
  label: string;
  type?: string;
  choices?: string[];
  optional?: boolean;
};
const field = (
  key: string,
  label: string,
  type = "text",
  optional = false,
): FieldSpec => ({ key, label, type, optional });
const choice = (
  key: string,
  label: string,
  ...choices: string[]
): FieldSpec => ({ key, label, choices });
const source = field("soporte", "Referencia del soporte");
const person = field("responsable", "Responsable");
const code = field("codigo", "Código maestro del producto");
const quantity = field("cantidad", "Cantidad", "number");
const date = field("fecha", "Fecha", "date");
const notes = (key: string, label: string) => field(key, label, "textarea");
const price = field("precio", "Precio por unidad (COP)", "number");
export const sections: Record<
  string,
  { name: string; singular: string; fields: FieldSpec[] }
> = {
  ficha: {
    name: "Fichas de fabricación",
    singular: "Ficha",
    fields: [
      code,
      choice("origen", "Origen", "Fabricación interna", "Comprado terminado"),
      field("unidad", "Unidad de análisis"),
      field("presentacion", "Presentación"),
      notes("materiales", "Materiales, insumos y cantidades teóricas"),
      notes("ruta", "Etapas en orden (una por línea)"),
    ],
  },
  ot: {
    name: "Órdenes de trabajo",
    singular: "OT",
    fields: [
      field(
        "acta",
        "Acta de la reunión de Ventas, Producción y Administración",
      ),
    ],
  },
  lote: { name: "Lotes", singular: "Lote", fields: [source] },
  traslado: {
    name: "Traslados entre áreas",
    singular: "Traslado",
    fields: [
      field("destino", "Área receptora (nombre registrado en Equipo)"),
      quantity,
      source,
    ],
  },
  carreta: {
    name: "Carretas",
    singular: "Carreta",
    fields: [field("metros", "Metros iniciales", "number")],
  },
  pedido_corte: {
    name: "OP confirmadas para corte",
    singular: "OP de corte",
    fields: [
      field("op", "Número de OP de Ventas"),
      code,
      field("metros", "Metros autorizados", "number"),
      source,
    ],
  },
  corte: {
    name: "Cortes y despachos",
    singular: "Corte",
    fields: [field("metros", "Metros a reservar", "number"), source],
  },
  rotulo: {
    name: "Rótulos",
    singular: "Rótulo",
    fields: [
      choice(
        "categoria",
        "Serie",
        "Alambre Eco",
        "Alambre Plus",
        "Alambre Desnudo",
        "Cable 7 Hilos",
        "Cobre para Pinos",
        "Aluminio",
      ),
      quantity,
      field("unidad", "Unidad"),
      field("ubicacion", "Área de origen"),
    ],
  },
  entrega: {
    name: "Lotes y entregas",
    singular: "Entrega",
    fields: [quantity, field("bodega", "Bodega física de destino"), source],
  },
  recuperacion: {
    name: "Recuperación",
    singular: "Recuperación",
    fields: [
      field("factura", "Factura y partida"),
      field("proveedor", "Proveedor de la partida"),
      field("remision", "Remisión de esta entrega parcial"),
      date,
      field("material", "Material"),
      field("facturado", "Peso facturado (kg)", "number"),
      field("fisico", "Peso verificado (kg)", "number", true),
      field("sinPesaje", "Motivo si falta pesaje", "text", true),
      notes("destino", "Destino de los componentes"),
    ],
  },
  servicio: {
    name: "Proveedores y costos",
    singular: "Partida",
    fields: [
      field("proveedor", "Proveedor"),
      field("factura", "Factura"),
      field("partida", "Partida o trabajo"),
      field("vencimiento", "Vencimiento", "date"),
      field("valor", "Valor facturado (COP)", "number"),
      source,
    ],
  },
  conteo: {
    name: "Conteos por área",
    singular: "Conteo",
    fields: [
      code,
      field("ubicacion", "Ubicación"),
      choice(
        "clase",
        "Clase",
        "Producto terminado",
        "Materia prima",
        "Insumos de fabricación",
        "Chatarra",
        "Propiedad, planta y equipo",
      ),
      field("fisico", "Cantidad física", "number"),
      field("teorico", "Existencia al corte", "number"),
      source,
    ],
  },
  costo: {
    name: "Costos y rendimientos",
    singular: "Análisis",
    fields: [
      code,
      field("periodo", "Período", "month"),
      field("base", "Material o concepto y unidad de análisis"),
      field("teorico", "Costo teórico (COP)", "number"),
      field("real", "Costo real sustentado (COP)", "number"),
      source,
    ],
  },
  garantia: {
    name: "Garantías",
    singular: "Garantía",
    fields: [
      field("factura", "Factura original"),
      code,
      choice(
        "familia",
        "Clasificación",
        "Cable 7 Hilos dañado",
        "Otro material",
      ),
      field("medida", "Unidad de medida o peso"),
      quantity,
      field("pagado", "Precio pagado por unidad (COP)", "number"),
      notes("origen", "Verificación de origen"),
      notes("dictamen", "Dictamen técnico y solución solicitada"),
      choice(
        "destino",
        "Destino técnico",
        "Cortas",
        "Recuperación",
        "Chatarra",
      ),
    ],
  },
  precio: {
    name: "Listas de precios",
    singular: "Precio",
    fields: [
      field("lista", "Nombre de la lista"),
      code,
      price,
      field("vigente", "Vigente desde", "date"),
    ],
  },
  cierre: {
    name: "Cierres mensuales",
    singular: "Cierre",
    fields: [field("periodo", "Mes", "month"), source],
  },
  caso: {
    name: "Novedades y autorizaciones",
    singular: "Caso",
    fields: [
      field("origen", "Módulo de origen"),
      field("documento", "Identificador del documento"),
      choice(
        "claseCaso",
        "Tipo de caso",
        "Autorización",
        "Novedad informativa",
      ),
      choice("importancia", "Importancia", "Media", "Alta", "Baja"),
      field("areaResponsable", "Área responsable"),
      person,
      source,
    ],
  },
  proyecto: {
    name: "Proyectos y proyecciones",
    singular: "Proyecto",
    fields: [
      notes("objetivo", "Objetivo"),
      choice(
        "escenario",
        "Escenario",
        "Proyecto",
        "Compras",
        "Ventas",
        "Gastos",
        "Caja",
        "Obligaciones",
        "Inversiones",
        "Capacidad productiva",
      ),
      person,
      date,
      field("fechaFin", "Fecha objetivo", "date", true),
      field("documentos", "Documentos asociados", "text", true),
      field("indicador", "Indicador de seguimiento", "text", true),
      notes("supuestos", "Supuestos del escenario"),
      field("presupuesto", "Presupuesto previsto (COP)", "number"),
    ],
  },
  expediente: {
    name: "Documentación confidencial",
    singular: "Expediente",
    fields: [
      field("asunto", "Asunto"),
      choice(
        "claseDocumento",
        "Tipo de documento",
        "Acuerdo societario",
        "Decisión gerencial",
        "Proyección",
        "Otro",
      ),
      field("vigencia", "Vigente hasta", "date", true),
      field("vinculo", "Proyecto o documento relacionado", "text", true),
      choice("nivel", "Nivel de acceso", "Dirección", "CREADOR"),
      date,
      person,
      field("archivo", "Documento PDF (hasta 3 MB)", "file"),
    ],
  },
};
export const plantKinds = [
  "ot",
  "ficha",
  "recuperacion",
  "servicio",
  "rotulo",
  "traslado",
  "conteo",
  "costo",
  "lote",
  "entrega",
  "carreta",
  "pedido_corte",
  "corte",
  "garantia",
  "precio",
  "cierre",
  "caso",
];
export const accessProfiles = [
  "COLABORADOR",
  "PRODUCCIÓN",
  "VENTAS",
  "BODEGA",
  "GERENTE DE VENTAS",
  "PRESIDENTE",
  "SOCIO ACCIONISTA",
  "GERENTE",
];
export const rightsLabels: Record<string, string> = {
  "planta.ver": "Consultar Producción",
  "planta.registrar": "Registrar en Producción",
  "planta.verificar": "Verificar procesos y cierres",
  "bodega.recibir": "Confirmar recepción física",
  "control.ver": "Entrar a Control Administrativo",
  "control.personas": "Consultar perfiles",
  "control.administrar_permisos":
    "Administrar los permisos delegables de otras personas",
  "control.aprobar": "Resolver autorizaciones",
  "control.seguimiento": "Gestionar novedades",
  "control.panel": "Consultar panel gerencial",
  "control.proyectos": "Gestionar proyectos",
  "archivo.ver": "Consultar expedientes",
  "archivo.descargar": "Descargar archivos",
  "archivo.editar": "Crear y versionar expedientes",
  "control.auditar": "Consultar auditoría",
};
export function orderLines(row?: Row): Line[] {
  return Array.isArray(row?.data.lineas) ? row.data.lineas : [];
}
export function ref(row: Row) {
  if (row.kind === "rotulo" && row.data.numero)
    return String(row.data.categoria) + " · " + row.data.numero;
  if (row.kind === "lote" && row.data.numero) return "Lote " + row.data.numero;
  return (sections[row.kind]?.singular ?? row.kind) + " " + row.series;
}
export function materialsOf(row?: Row): {
  clave: string;
  codigo: string;
  unidad: string;
  bodega: string;
  teorico: number;
  consumido: number;
  reservado: number;
  faltante: number;
}[] {
  return Array.isArray(row?.data.reservasMaterial)
    ? row.data.reservasMaterial
    : [];
}

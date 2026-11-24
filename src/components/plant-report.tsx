"use client";
import { useState, type FormEvent } from "react";
import { getSupabaseClient } from "@/lib/supabase/client";
import { todayBogota } from "@/lib/finance";
import { sections, plantKinds } from "@/lib/plant-forms";
type Entry = Record<string, string | number>;
const columns = [
  "serie",
  "tipo",
  "documento",
  "estado",
  "version",
  "fecha",
  "responsable",
  "codigo",
  "cantidad",
  "teorico",
  "real",
  "periodo",
];
const titles = [
  "Consecutivo",
  "Tipo",
  "Documento",
  "Estado",
  "Versión",
  "Último movimiento",
  "Responsable",
  "Producto",
  "Cantidad",
  "Teórico",
  "Real",
  "Período",
];
function csv(value: unknown) {
  const s = String(value ?? "");
  return (
    '"' + (/^[\s]*[=+@-]/.test(s) ? "'" : "") + s.replaceAll('"', '""') + '"'
  );
}
export function PlantReport() {
  const [rows, setRows] = useState<Entry[] | null>(null),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false);
  const today = todayBogota();
  async function fetchReport(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget),
      client = getSupabaseClient();
    if (!client || busy) return;
    const download =
      (e.nativeEvent as SubmitEvent).submitter?.getAttribute("value") === "csv";
    setBusy(true);
    setError("");
    try {
      const r = await client.rpc("plant_report", {
        start_date: f.get("inicio"),
        end_date: f.get("fin"),
        kind_filter: f.get("tipo"),
        sku: f.get("sku"),
        exporting: download,
      });
      if (r.error) throw new Error(r.error.message);
      const entries: Entry[] = r.data ?? [];
      setRows(entries);
      if (download) {
        const lines = [
          titles.map(csv),
          ...entries.map((x) => columns.map((c) => csv(x[c]))),
        ];
        const url = URL.createObjectURL(
          new Blob(["\uFEFF" + lines.map((l) => l.join(";")).join("\r\n")], {
            type: "text/csv;charset=utf-8",
          }),
        );
        const a = document.createElement("a");
        a.href = url;
        a.download =
          "Produccion-" + f.get("inicio") + "-" + f.get("fin") + ".csv";
        a.click();
        setTimeout(() => URL.revokeObjectURL(url), 5000);
      }
    } catch (err) {
      setRows(null);
      setError(
        err instanceof Error ? err.message : "No se pudo consultar el informe.",
      );
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="plant-editor">
      <h3>Histórico de Producción</h3>
      <p>
        Documentos con actividad en el período y su última versión al cierre de
        la fecha final.
      </p>
      <form
        className="plant-fields"
        onSubmit={fetchReport}
        onChange={() => setRows(null)}
      >
        <label>
          Desde
          <input
            name="inicio"
            type="date"
            required
            defaultValue={today.slice(0, 7) + "-01"}
            max={today}
          />
        </label>
        <label>
          Hasta
          <input
            name="fin"
            type="date"
            required
            defaultValue={today}
            max={today}
          />
        </label>
        <label>
          Proceso
          <select name="tipo">
            <option value="">Todos</option>
            {plantKinds
              .filter((k) => k !== "caso")
              .map((k) => (
                <option key={k} value={k}>
                  {sections[k].name}
                </option>
              ))}
          </select>
        </label>
        <label>
          Código de producto
          <input name="sku" />
        </label>
        <button disabled={busy}>Consultar</button>
        <button value="csv" disabled={busy}>
          Descargar CSV
        </button>
      </form>
      {error && <p role="alert">{error}</p>}
      {rows && (
        <>
          <p>{rows.length} documentos en el período</p>
          {rows.map((x) => (
            <div className="plant-row" key={x.serie}>
              <div>
                <strong>
                  {x.documento} · {x.estado}
                </strong>
                <small>
                  {sections[x.tipo]?.singular} {x.serie} · v{x.version} ·{" "}
                  {x.responsable}
                </small>
              </div>
              {x.tipo === "costo" && (
                <div>
                  {["teorico", "real"].map((k) => (
                    <label key={k}>
                      {k === "real" ? "Real" : "Teórico"} ·{" "}
                      {Number(x[k]).toLocaleString("es-CO")} COP{" "}
                      <meter
                        value={Number(x[k])}
                        min={0}
                        max={Math.max(Number(x.teorico), Number(x.real), 1)}
                      />
                    </label>
                  ))}
                </div>
              )}
            </div>
          ))}
        </>
      )}
    </div>
  );
}

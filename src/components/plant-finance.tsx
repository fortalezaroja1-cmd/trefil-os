"use client";
import { useEffect, useState } from "react";
import { getSupabaseClient } from "@/lib/supabase/client";
import { todayBogota, formatCOP } from "@/lib/finance";
type Finance = {
  cuentas: { cuenta: string; saldo_cop: string }[];
  pendientes: { id: string; motivo: string; fecha: string }[];
  corte: string;
  deudas: { tipo: string; capital: number; abonado: number; saldo: number }[];
  conciliaciones: {
    cuenta: string;
    fecha: string;
    diferencia: number;
    extracto: number;
  }[];
};
export function PlantFinance() {
  const [cut, setCut] = useState(todayBogota());
  const [data, setData] = useState<Finance | null>(null);
  const [error, setError] = useState("");
  const [refresh, setRefresh] = useState(0);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let active = true;
    setData(null);
    setError("");
    const client = getSupabaseClient();
    if (!client || !cut) return;
    void client.rpc("plant_management_cut", { cutoff: cut }).then((r) => {
      if (!active) return;
      if (r.error) setError(r.error.message);
      else setData(r.data);
    });
    return () => {
      active = false;
    };
  }, [cut, refresh]);
  return (
    <section className="plant-editor">
      <h2>Caja y aprobaciones financieras</h2>
      <label>
        Fecha de corte
        <input
          type="date"
          value={cut}
          max={todayBogota()}
          onChange={(e) => setCut(e.target.value)}
        />
      </label>
      {error && <p role="alert">{error}</p>}
      {data && (
        <>
          <p>Fuente: libro institucional de Caja · {data.corte}</p>
          {data.cuentas.length === 0 ? (
            <p>Sin cuentas visibles para este corte y sesión.</p>
          ) : (
            data.cuentas.map((c, i) => (
              <div className="plant-row" key={i}>
                <strong>{c.cuenta}</strong>
                <span>{formatCOP(c.saldo_cop)}</span>
              </div>
            ))
          )}
          <h3>Capital y abonos de Deudas</h3>
          {data.deudas.length === 0 && <p>Sin deudas visibles a este corte.</p>}
          {data.deudas.map((d) => (
            <div className="plant-row" key={d.tipo}>
              <strong>{d.tipo === "loan" ? "Préstamos" : "Inversiones"}</strong>
              <span>
                Capital {formatCOP(String(d.capital))} · Abonado{" "}
                {formatCOP(String(d.abonado))} · Saldo{" "}
                {formatCOP(String(d.saldo))}
              </span>
            </div>
          ))}
          <h3>Última conciliación por cuenta</h3>
          {data.conciliaciones.length === 0 && (
            <p>Sin conciliaciones visibles a este corte.</p>
          )}
          {data.conciliaciones.map((r, i) => (
            <div className="plant-row" key={i}>
              <strong>
                {r.cuenta} · {r.fecha}
              </strong>
              <span>
                Extracto {formatCOP(String(r.extracto))} · Diferencia{" "}
                {formatCOP(String(r.diferencia))}
              </span>
            </div>
          ))}
          {data.pendientes.map((p) => (
            <form
              key={p.id}
              onSubmit={async (e) => {
                e.preventDefault();
                const fields = new FormData(e.currentTarget);
                const client = getSupabaseClient();
                if (!client || busy) return;
                setBusy(true);
                try {
                  const r = await client.rpc("decide_financial_transaction", {
                    p_id: p.id,
                    p_approve: fields.get("decision") === "aprobar",
                    p_reason: fields.get("motivo"),
                  });
                  if (r.error) setError(r.error.message);
                  else setRefresh((v) => v + 1);
                } finally {
                  setBusy(false);
                }
              }}
            >
              <strong>{p.motivo}</strong>
              <small>{p.id}</small>
              <label>
                Decisión
                <select name="decision">
                  <option value="aprobar">Aprobar</option>
                  <option value="rechazar">Rechazar</option>
                </select>
              </label>
              <label>
                Motivo
                <input name="motivo" required minLength={3} />
              </label>
              <button className="button button-secondary" disabled={busy}>
                Registrar decisión en Caja
              </button>
            </form>
          ))}
        </>
      )}
    </section>
  );
}

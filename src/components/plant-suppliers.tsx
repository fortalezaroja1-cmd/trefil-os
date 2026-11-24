"use client";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { getSupabaseClient } from "@/lib/supabase/client";
import { formatCOP } from "@/lib/finance";
type Application = {
  id: string;
  tipo: string;
  estado: string;
  monto: number;
  soporte: string;
  autor: string;
};
type Part = {
  id: string;
  proveedor: string;
  factura: string;
  partida: string;
  vencimiento: string;
  facturado: number;
  aplicado: number;
  por_pagar: number;
  por_cobrar: number;
  aplicaciones: Application[];
};
type Props = {
  write?: boolean;
  approve?: boolean;
  actor?: string;
  revision?: string;
};
const money = (value: number) => formatCOP(String(value));

export function PlantSuppliers({
  write = false,
  approve = false,
  actor,
  revision = "",
}: Props) {
  const [rows, setRows] = useState<Part[]>([]),
    [error, setError] = useState(""),
    [note, setNote] = useState("");
  const [part, setPart] = useState(""),
    [mode, setMode] = useState("Caja"),
    [search, setSearch] = useState("");
  const [sources, setSources] = useState<{ id: string; etiqueta: string }[]>(
      [],
    ),
    [seq, setSeq] = useState(0),
    [busy, setBusy] = useState(false);
  const pending = useRef<{ key: string; id: string } | null>(null),
    lock = useRef(false);
  useEffect(() => {
    const client = getSupabaseClient();
    if (!client) return;
    let active = true;
    void client.rpc("plant_supplier_accounts").then((r) => {
      if (!active) return;
      if (r.error) {
        setRows([]);
        setError(r.error.message);
      } else setRows(r.data ?? []);
    });
    const sub = client.auth.onAuthStateChange((evt) => {
      if (evt === "SIGNED_OUT") {
        active = false;
        setRows([]);
        setSources([]);
        setPart("");
      }
    });
    return () => {
      active = false;
      sub.data.subscription.unsubscribe();
    };
  }, [seq, revision]);
  useEffect(() => {
    setSources([]);
    if (!part || !write) return;
    let current = true;
    const timer = setTimeout(async () => {
      const client = getSupabaseClient();
      if (!client) return;
      const r = await client.rpc("plant_supplier_sources", {
        part_id: part,
        mode,
        search_term: search,
      });
      if (current) {
        if (r.error) setError(r.error.message);
        else setSources(r.data ?? []);
      }
    }, 180);
    return () => {
      current = false;
      clearTimeout(timer);
    };
  }, [part, mode, search, write]);
  async function save(
    e: FormEvent<HTMLFormElement>,
    partId: string,
    id?: string,
  ) {
    e.preventDefault();
    if (lock.current) return;
    const form = e.currentTarget,
      fd = new FormData(form);
    const client = getSupabaseClient();
    if (!client) return;
    const operation = String(fd.get("decision") ?? "solicitar"),
      reason = String(fd.get("motivo") ?? "");
    const payload = id
      ? {}
      : Object.fromEntries(
          ["documento", "cantidad", "precio", "monto"]
            .map((k) => [k, fd.get(k)])
            .concat([["tipo", mode]]),
        );
    const key = JSON.stringify([partId, operation, reason, payload]);
    if (pending.current?.key !== key)
      pending.current = { key, id: crypto.randomUUID() };
    lock.current = true;
    setBusy(true);
    setError("");
    setNote("");
    try {
      const result = await client.rpc("plant_supplier_action", {
        part_id: partId,
        entry_id: id ?? pending.current.id,
        operation,
        payload,
        note: reason,
      });
      if (result.error) throw new Error(result.error.message);
      pending.current = null;
      form.reset();
      setPart("");
      setSeq((v) => v + 1);
      setNote(
        id
          ? "Decisión registrada."
          : "Aplicación enviada a Control Administrativo.",
      );
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : "No se pudo guardar la aplicación.",
      );
    } finally {
      lock.current = false;
      setBusy(false);
    }
  }
  return (
    <section className="plant-editor">
      <h3>Facturas y cruces de proveedores</h3>
      {error && <p role="alert">{error}</p>}
      {note && <p role="status">{note}</p>}
      {rows.length === 0 && <p>Sin partidas de proveedor visibles.</p>}
      {rows.map((p) => (
        <details className="plant-item" key={p.id}>
          <summary>
            <strong>
              {p.proveedor} · {p.factura} · {p.partida}
            </strong>
            <span>{money(p.por_pagar)} por pagar</span>
          </summary>
          <p>
            Vence {p.vencimiento} · Facturado {money(p.facturado)} · Aplicado{" "}
            {money(p.aplicado)} · Por cobrar al proveedor {money(p.por_cobrar)}
          </p>
          {p.aplicaciones.map((a) => (
            <div key={a.id}>
              <p>
                {a.tipo} · {money(a.monto)} · {a.estado} · {a.soporte}
              </p>
              {approve && a.estado === "pendiente" && a.autor !== actor && (
                <form
                  className="plant-fields"
                  onSubmit={(e) => void save(e, p.id, a.id)}
                >
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
                  <button disabled={busy}>Registrar decisión</button>
                </form>
              )}
            </div>
          ))}
          {write && part !== p.id && (
            <button
              onClick={() => {
                setPart(p.id);
                setSearch("");
                setError("");
              }}
            >
              Aplicar abono o compensación
            </button>
          )}
          {write && part === p.id && (
            <form className="plant-fields" onSubmit={(e) => void save(e, p.id)}>
              <label>
                Origen
                <select value={mode} onChange={(e) => setMode(e.target.value)}>
                  <option>Caja</option>
                  <option>Chatarra</option>
                </select>
              </label>
              <label>
                Buscar soporte original
                <input
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                />
              </label>
              <label>
                Movimiento ya registrado
                <select
                  name="documento"
                  key={part + mode + search}
                  defaultValue=""
                  required
                >
                  <option value="">Selecciona un movimiento</option>
                  {sources.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.etiqueta}
                    </option>
                  ))}
                </select>
              </label>
              {mode === "Chatarra" && (
                <>
                  <label>
                    Cantidad entregada en unidad del movimiento
                    <input
                      name="cantidad"
                      type="number"
                      min="0.000001"
                      step="0.000001"
                      required
                    />
                  </label>
                  <label>
                    Precio acordado por unidad (COP)
                    <input
                      name="precio"
                      type="number"
                      min="0.01"
                      step="0.01"
                      required
                    />
                  </label>
                </>
              )}
              <label>
                Monto aplicado (COP)
                <input
                  name="monto"
                  type="number"
                  min="0.01"
                  step="0.01"
                  required
                />
              </label>
              <label>
                Acuerdo o soporte
                <input name="motivo" minLength={3} required />
              </label>
              <button type="button" onClick={() => setPart("")}>
                Cancelar
              </button>
              <button disabled={busy}>Solicitar aplicación</button>
            </form>
          )}
        </details>
      ))}
    </section>
  );
}

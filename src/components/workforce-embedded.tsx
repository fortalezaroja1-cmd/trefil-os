"use client";

import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import { KeyRound, LoaderCircle, ShieldCheck } from "lucide-react";
import { getSupabaseClient, publicSupabaseConfiguration } from "@/lib/supabase/client";
import {
  signInWithDocument,
  workforceRpc,
  WorkforceError,
  type WorkforceDay,
} from "@/lib/workforce";
import { Field } from "./ui";
import { TeamManagement } from "./workforce-team";
import type { Perform } from "./workforce-app";

function messageFor(reason: unknown) {
  return reason instanceof WorkforceError
    ? reason.message
    : "No pudimos abrir Equipo. Revisa la conexión e inténtalo de nuevo.";
}

export function WorkforceEmbedded() {
  const configuration = publicSupabaseConfiguration();
  const [snapshot, setSnapshot] = useState<WorkforceDay | null>(null);
  const [checking, setChecking] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const locked = useRef(false);

  const load = useCallback(async (client: SupabaseClient) => {
    setChecking(true);
    try {
      const next = await workforceRpc<WorkforceDay>(client, "workforce_day", { p_day: null });
      setSnapshot(next);
      setError("");
    } catch (reason) {
      setSnapshot(null);
      setError(messageFor(reason));
    } finally {
      setChecking(false);
    }
  }, []);

  useEffect(() => {
    const client = getSupabaseClient();
    if (!client) {
      setChecking(false);
      return;
    }
    let active = true;
    void client.auth.getSession().then(({ data }) => {
      if (!active) return;
      if (data.session) void load(client);
      else setChecking(false);
    });
    const { data: { subscription } } = client.auth.onAuthStateChange((event, session) => {
      if (!active) return;
      if (!session || event === "SIGNED_OUT") {
        setSnapshot(null);
        setChecking(false);
        return;
      }
      if (event === "SIGNED_IN" || event === "TOKEN_REFRESHED") void load(client);
    });
    return () => {
      active = false;
      subscription.unsubscribe();
    };
  }, [load]);

  const perform: Perform = async (operation, success, shouldRefresh = true) => {
    const client = getSupabaseClient();
    if (!client || locked.current) return;
    locked.current = true;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await operation(client);
      if (success) setNotice(success);
      if (shouldRefresh) await load(client);
    } catch (reason) {
      setError(messageFor(reason));
    } finally {
      locked.current = false;
      setBusy(false);
    }
  };

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    const fields = new FormData(form);
    void perform(async (client) => {
      await signInWithDocument(
        client,
        String(fields.get("document") ?? ""),
        String(fields.get("password") ?? ""),
      );
      form.reset();
      await load(client);
    }, undefined, false);
  }

  if (!configuration.configured) {
    return <section className="workforce-embedded-state error"><ShieldCheck size={22} /><div><h2>Equipo no está disponible</h2><p>{configuration.reason}</p></div></section>;
  }

  if (checking) {
    return <section className="workforce-embedded-state"><span className="workforce-spinner"><LoaderCircle size={24} /></span><div><h2>Abriendo Equipo</h2><p>Usando tu sesión actual de Trefil OS.</p></div></section>;
  }

  if (!snapshot) {
    return (
      <section className="workforce-embedded-login">
        <div>
          <p className="workforce-eyebrow">ACCESO DE EQUIPO</p>
          <h2>Inicia sesión sin salir de Trefil OS</h2>
          <p>La lista de personas se abrirá aquí mismo y conservará la navegación principal.</p>
        </div>
        <form onSubmit={submit}>
          <Field label="Número de cédula o correo"><input name="document" autoComplete="username" required /></Field>
          <Field label="Contraseña"><input name="password" type="password" autoComplete="current-password" required /></Field>
          <button className="button button-primary" disabled={busy}><KeyRound size={16} /> Iniciar sesión</button>
        </form>
        {error && <p className="workforce-feedback error" role="alert">{error}</p>}
      </section>
    );
  }

  return (
    <div className="workforce-embedded">
      {notice && <p className="workforce-feedback" role="status">{notice}</p>}
      {error && <p className="workforce-feedback error" role="alert">{error}</p>}
      <TeamManagement snapshot={snapshot} busy={busy} perform={perform} />
    </div>
  );
}

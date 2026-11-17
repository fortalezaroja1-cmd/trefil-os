"use client";

import Image from "next/image";
import Link from "next/link";
import { Bot, Check, KeyRound, LoaderCircle, ShieldCheck, X } from "lucide-react";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { getSupabaseClient } from "@/lib/supabase/client";
import { signInWithDocument } from "@/lib/workforce";
import { Field } from "./ui";

type AuthorizationDetails = { client?: { name?: string }; redirect_uri?: string; scope?: string };
type ConnectedProfile = { name: string; job_title: string; area: string; role: string; permissions: string[] };

export function OAuthConsentApp() {
  const [authorizationId,setAuthorizationId]=useState("");
  const [screen,setScreen]=useState<"loading"|"signin"|"consent"|"blocked">("loading");
  const [details,setDetails]=useState<AuthorizationDetails|null>(null);
  const [profile,setProfile]=useState<ConnectedProfile|null>(null);
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState("");

  const load=useCallback(async(id:string)=>{
    const client=getSupabaseClient();
    if(!client){setError("La conexión institucional no está disponible.");setScreen("blocked");return;}
    const {data:{session}}=await client.auth.getSession();
    if(!session){setScreen("signin");return;}
    const [{data:authorization,error:authorizationError},{data:userProfile,error:profileError}]=await Promise.all([
      client.auth.oauth.getAuthorizationDetails(id), client.rpc("developer_oauth_profile"),
    ]);
    if(authorizationError){setError("La solicitud de conexión venció o no es válida. Vuelve a iniciarla desde ChatGPT.");setScreen("blocked");return;}
    if(profileError||!userProfile?.id){setError("Tu cuenta no tiene habilitado el permiso “Conectar asistentes de IA”. El administrador puede activarlo desde Equipo y permisos.");setScreen("blocked");return;}
    setDetails(authorization as AuthorizationDetails);setProfile(userProfile as ConnectedProfile);setScreen("consent");
  },[]);

  useEffect(()=>{const id=new URLSearchParams(window.location.search).get("authorization_id")??"";setAuthorizationId(id);if(!id){setError("Falta la solicitud de conexión. Inicia la conexión desde ChatGPT.");setScreen("blocked");return;}void load(id);},[load]);

  async function submitLogin(event:FormEvent<HTMLFormElement>){event.preventDefault();const client=getSupabaseClient();if(!client)return;const fields=new FormData(event.currentTarget);setBusy(true);setError("");try{await signInWithDocument(client,String(fields.get("document")??""),String(fields.get("password")??""));await load(authorizationId);}catch(reason){setError(reason instanceof Error?reason.message:"No se pudo iniciar sesión.");}finally{setBusy(false);}}
  async function decide(decision:"approve"|"deny"){const client=getSupabaseClient();if(!client)return;setBusy(true);setError("");const result=decision==="approve"?await client.auth.oauth.approveAuthorization(authorizationId):await client.auth.oauth.denyAuthorization(authorizationId);setBusy(false);if(result.error||!result.data?.redirect_url){setError("No se pudo completar la autorización. Vuelve a intentarlo.");return;}window.location.assign(result.data.redirect_url);}

  return <main className="oauth-shell"><section className="oauth-brand"><Image src="/brand/trefielectric-logo.jpg" alt="TrefiElectric" width={260} height={260} priority/><div><Bot/><p>CONEXIÓN MCP</p><h1>ChatGPT trabajará con tus permisos.</h1><span>No se comparte tu cédula ni tu contraseña. Cada acción conserva tu identidad laboral y los límites definidos en Equipo.</span></div></section><section className="oauth-card">
    {screen==="loading"&&<State icon={<LoaderCircle className="spin"/>} title="Preparando conexión" text="Verificando la solicitud y tu sesión de Trefil OS…"/>}
    {screen==="signin"&&<><div className="oauth-heading"><KeyRound/><p>TREFIL OS</p><h2>Identifícate para conectar ChatGPT</h2><span>Usa las mismas credenciales de Equipo.</span></div><form onSubmit={submitLogin} className="oauth-form"><Field label="Correo o número de cédula"><input name="document" autoComplete="username" required/></Field><Field label="Contraseña"><input name="password" type="password" autoComplete="current-password" required/></Field><button className="button button-primary" disabled={busy}><ShieldCheck size={17}/>Continuar de forma segura</button></form>{error&&<p className="oauth-error" role="alert">{error}</p>}</>}
    {screen==="consent"&&details&&profile&&<><div className="oauth-heading"><ShieldCheck/><p>AUTORIZACIÓN INDIVIDUAL</p><h2>Conectar {details.client?.name||"ChatGPT"}</h2><span>La conexión quedará anclada a tu usuario de Trefil OS.</span></div><div className="oauth-person"><strong>{profile.name}</strong><span>{profile.job_title} · {profile.area}</span></div><div className="oauth-permissions"><h3>Esta conexión podrá</h3><ul><li>Identificar tu rol sin revelar tu cédula.</li><li>Mostrar solo herramientas autorizadas para tu cuenta.</li><li>Consultar tus tareas si tienes ese permiso.</li><li>Programar tareas únicamente si tu rol lo permite.</li></ul></div><p className="oauth-live"><Check/>Los cambios hechos por el administrador en Equipo se aplican de inmediato.</p><div className="oauth-actions"><button className="button button-secondary" disabled={busy} onClick={()=>void decide("deny")}><X size={16}/>Cancelar</button><button className="button button-primary" disabled={busy} onClick={()=>void decide("approve")}><Bot size={16}/>Autorizar ChatGPT</button></div>{error&&<p className="oauth-error" role="alert">{error}</p>}</>}
    {screen==="blocked"&&<State icon={<ShieldCheck/>} title="No se puede conectar" text={error} action={<Link href="/equipo/">Volver a Equipo</Link>}/>} 
  </section></main>;
}
function State({icon,title,text,action}:{icon:React.ReactNode;title:string;text:string;action?:React.ReactNode}){return <div className="oauth-state">{icon}<h2>{title}</h2><p>{text}</p>{action}</div>}

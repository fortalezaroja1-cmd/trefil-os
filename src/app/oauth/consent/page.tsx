import type { Metadata } from "next";
import { OAuthConsentApp } from "@/components/oauth-consent-app";
import "./consent.css";

export const metadata:Metadata={
  title:"Autorizar ChatGPT · Trefil OS",
  description:"Autoriza una conexión MCP con los permisos de tu usuario de Trefil OS.",
  robots:{index:false,follow:false},
  referrer:"no-referrer",
};

export default function OAuthConsentPage(){return <OAuthConsentApp/>;}

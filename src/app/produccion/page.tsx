import type { Metadata } from "next";
import { PlantWorkspace } from "@/components/plant-workspace";
import "../plant.css";
export const metadata: Metadata = { title: "Producción · Trefil OS" };
export default function Page() {
  return <PlantWorkspace area="produccion" />;
}

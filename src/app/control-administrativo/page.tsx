import type { Metadata } from "next";
import { PlantWorkspace } from "@/components/plant-workspace";
import "../plant.css";
export const metadata: Metadata = {
  title: "Control Administrativo · Trefil OS",
};
export default function Page() {
  return <PlantWorkspace area="control" />;
}

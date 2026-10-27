import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";

async function start() {
  // Previewing in a plain browser during development: answer backend calls from a fixture.
  if (import.meta.env.DEV && !("__TAURI_INTERNALS__" in window)) {
    await (await import("./dev/mock")).installMock();
  }
  ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
    <React.StrictMode>
      <App />
    </React.StrictMode>,
  );
}

start();

/**
 * MonsieurPapin Extension - Project tools for managing and running the research pipeline
 */

import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";

const testTool = defineTool({
  name: "run_tests",
  label: "Run Tests",
  description: "Run the Julia test suite for MonsieurPapin",
  parameters: Type.Object({
    file: Type.Optional(Type.String({ description: "Specific test file to run (e.g. core, llm, scoring)" })),
  }),

  async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
    const cmd = params.file
      ? `julia --project -e 'include("test/${params.file}.jl")'`
      : `julia --project test/runtests.jl`;

    try {
      const output = execSync(cmd, { cwd: process.cwd(), encoding: "utf8", timeout: 120000 });
      return {
        content: [{ type: "text", text: output }],
        details: { command: cmd },
      };
    } catch (e: any) {
      return {
        content: [{ type: "text", text: e.stdout || e.stderr || e.message }],
        details: { error: true },
      };
    }
  },
});

const settingsTool = defineTool({
  name: "read_settings",
  label: "Read Settings",
  description: "Read the current settings.toml configuration",
  parameters: Type.Object({}),

  async execute() {
    const { readFileSync } = await import("node:fs");
    const content = readFileSync("settings.toml", "utf8");
    return {
      content: [{ type: "text", text: content }],
      details: {},
    };
  },
});

export default function (pi: ExtensionAPI) {
  pi.registerTool(testTool);
  pi.registerTool(settingsTool);
}
import { defineConfig } from "hardhat/config";
import path from "node:path";

export default defineConfig({
  solidity: {
    version: "0.8.26",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
      evmVersion: "cancun",
    },
  },
  paths: {
    sources: "./src",
    tests: "./test/unit",
    cache: "./hardhat-cache",
    artifacts: "./hardhat-artifacts",
  },
  plugins: [
    {
      id: "coverage-filter",
      hookHandlers: {
        solidity: async () => ({
          default: async () => ({
            preprocessProjectFileBeforeBuilding: async (
              context,
              sourceName,
              fsPath,
              fileContent,
              solcVersion,
              next,
            ) => {
              // Skip coverage instrumentation for lib/ and test/ files.
              // Return original content directly so only src/ files appear
              // in the coverage report.
              if (context.globalOptions.coverage) {
                const rootDir = process.cwd();
                const rel = path.relative(rootDir, fsPath);

                if (
                  rel.startsWith("lib" + path.sep) ||
                  rel.startsWith("test" + path.sep)
                ) {
                  return fileContent;
                }
              }

              return next(
                context,
                sourceName,
                fsPath,
                fileContent,
                solcVersion,
              );
            },
          }),
        }),
      },
    },
  ],
});

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const rootDir = process.cwd();
const args = process.argv.slice(2);

function getArg(flag, fallback) {
  const index = args.indexOf(flag);
  return index === -1 ? fallback : args[index + 1] ?? fallback;
}

const config = {
  schemaPath: getArg("--schema", path.join(rootDir, "scripts", "service-config-schema.json")),
  mode: getArg("--mode", "noninteractive"),
  baoAddr: process.env.BAO_ADDR || "http://127.0.0.1:8200",
  baoToken: process.env.BAO_TOKEN || process.env.BAO_BOOTSTRAP_TOKEN,
  kvMount: process.env.BAO_KV_MOUNT || "kv",
  requestPath: process.env.CAID_CONFIG_REQUEST_PATH || "caid/config-requests",
};

function loadSchema() {
  return JSON.parse(fs.readFileSync(config.schemaPath, "utf8"));
}

async function baoFetch(method, relativePath, body) {
  if (!config.baoToken) {
    throw new Error("BAO_TOKEN or BAO_BOOTSTRAP_TOKEN is required.");
  }

  const response = await fetch(`${config.baoAddr}/v1/${relativePath}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      "X-Vault-Token": config.baoToken,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new Error(`OpenBao ${method} ${relativePath} failed (${response.status}): ${text}`);
  }

  if (response.status === 204) {
    return {};
  }

  return response.json();
}

async function readKv(pathName) {
  try {
    const payload = await baoFetch("GET", `${config.kvMount}/data/${pathName}`);
    return payload?.data?.data ?? {};
  } catch (error) {
    if (String(error.message).includes("(404)")) {
      return {};
    }

    throw error;
  }
}

async function writeKv(pathName, data) {
  await baoFetch("POST", `${config.kvMount}/data/${pathName}`, { data });
}

function requestId(service, key) {
  return `${service}:${key}`;
}

const generatedConfigDefaults = {
  netbird: {
    NETBIRD_HOST: { value: process.env.NETBIRD_HOST, generate: false },
    NETBIRD_OIDC_CLIENT_SECRET: {
      value: process.env.NETBIRD_OIDC_CLIENT_SECRET,
      generate: true,
    },
  },
  logging: {
    GRAFANA_HOST: { value: process.env.GRAFANA_HOST, generate: false },
    GRAFANA_ADMIN_PASSWORD: { value: process.env.GRAFANA_ADMIN_PASSWORD, generate: true },
  },
};

function generatedSecret() {
  return crypto.randomBytes(32).toString("base64url");
}

async function seedGeneratedDefaults(schema) {
  for (const service of schema.services ?? []) {
    const defaults = generatedConfigDefaults[service.service] ?? {};
    const values = await readKv(service.openbaoPath);
    const merged = { ...values };
    let changed = false;

    for (const [key, spec] of Object.entries(defaults)) {
      if (merged[key] === undefined || merged[key] === "") {
        if (typeof spec.value === "string" && spec.value !== "") {
          merged[key] = spec.value;
        } else if (spec.generate) {
          merged[key] = generatedSecret();
        } else {
          continue;
        }
        changed = true;
      }
    }

    if (changed) {
      await writeKv(service.openbaoPath, merged);
    }
  }
}

async function main() {
  const schema = loadSchema();
  await seedGeneratedDefaults(schema);
  const existingRequests = await readKv(config.requestPath);
  const now = new Date().toISOString();
  const requests = { ...existingRequests };
  let pendingCount = 0;

  for (const service of schema.services ?? []) {
    const values = await readKv(service.openbaoPath);

    for (const item of service.requiredValues ?? []) {
      const present = values[item.key] !== undefined && values[item.key] !== "";
      const id = requestId(service.service, item.key);

      if (present) {
        if (requests[id]?.status === "missing") {
          requests[id] = {
            ...requests[id],
            status: "provided",
            updatedAt: now,
          };
        }
        continue;
      }

      pendingCount += 1;
      requests[id] = {
        id,
        service: service.service,
        serviceTitle: service.title,
        key: item.key,
        label: item.label,
        description: item.description,
        secret: Boolean(item.secret),
        required: item.required !== false,
        targetPath: service.openbaoPath,
        placeholder: item.placeholder ?? "",
        status: "missing",
        createdAt: requests[id]?.createdAt ?? now,
        updatedAt: now,
      };
    }
  }

  await writeKv(config.requestPath, requests);

  if (pendingCount) {
    console.log(`CAId converge recorded ${pendingCount} pending human config value(s).`);
    console.log(`OpenBao path: ${config.kvMount}/data/${config.requestPath}`);

    if (config.mode === "noninteractive") {
      process.exitCode = 20;
    }
    return;
  }

  console.log("CAId converge found no missing human config values.");
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});

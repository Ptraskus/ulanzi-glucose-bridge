import { JsonSource } from "./sources/json.mjs";
import { MockSource } from "./sources/mock.mjs";
import { NightscoutSource } from "./sources/nightscout.mjs";

export function createSource(config) {
  if (config.source === "nightscout") return new NightscoutSource(config);
  if (config.source === "json") return new JsonSource(config);
  return new MockSource(config);
}

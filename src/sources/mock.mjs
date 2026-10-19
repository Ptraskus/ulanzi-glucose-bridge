import { normalizeReading } from "../reading.mjs";

export class MockSource {
  constructor(config) {
    this.config = config;
  }

  async getReading(now = new Date()) {
    return normalizeReading(
      {
        valueMgDl: this.config.mock.valueMgDl,
        trend: this.config.mock.trend,
        timestamp: new Date(now.getTime() - this.config.mock.ageMinutes * 60_000),
      },
      "simulador",
    );
  }
}

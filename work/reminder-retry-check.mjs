import assert from "node:assert/strict";
import fs from "node:fs";
import {
  DEVICE_RETRY_DELAY_MINUTES,
  MAX_ATTEMPTS,
  noDevicePlan,
  pushFailurePlan,
  retryDelayMinutes,
} from "../supabase-functions/xj-send-todo-reminders/retry-policy.mjs";

assert.equal(MAX_ATTEMPTS, 5);
assert.equal(retryDelayMinutes(1), 5);
assert.equal(retryDelayMinutes(2), 15);
assert.equal(retryDelayMinutes(3), 30);
assert.equal(retryDelayMinutes(4), 60);
assert.equal(retryDelayMinutes(5), null);

assert.deepEqual(pushFailurePlan(1), {
  status: "pending",
  failureCode: "push_failed",
  delayMinutes: 5,
});
assert.deepEqual(pushFailurePlan(5), {
  status: "failed",
  failureCode: "retry_limit_reached",
  delayMinutes: null,
});
assert.deepEqual(noDevicePlan(), {
  status: "pending",
  failureCode: "waiting_for_device",
  delayMinutes: DEVICE_RETRY_DELAY_MINUTES,
});

const indexHtml = fs.readFileSync(new URL("../index.html", import.meta.url), "utf8");
assert.match(indexHtml, /\.in\("status",\["pending","sending","failed"\]\)/);

console.log("reminder retry policy: PASS");

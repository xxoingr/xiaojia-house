export const MAX_ATTEMPTS = 5;
export const DEVICE_RETRY_DELAY_MINUTES = 30;

const RETRY_DELAYS_MINUTES = Object.freeze([5, 15, 30, 60]);

export function retryDelayMinutes(attemptNumber) {
  const attempt = Number(attemptNumber);
  if (!Number.isInteger(attempt) || attempt < 1 || attempt >= MAX_ATTEMPTS) return null;
  return RETRY_DELAYS_MINUTES[attempt - 1] ?? null;
}

export function pushFailurePlan(attemptNumber) {
  const delayMinutes = retryDelayMinutes(attemptNumber);
  if (delayMinutes === null) {
    return { status: "failed", failureCode: "retry_limit_reached", delayMinutes: null };
  }
  return { status: "pending", failureCode: "push_failed", delayMinutes };
}

export function noDevicePlan() {
  return {
    status: "pending",
    failureCode: "waiting_for_device",
    delayMinutes: DEVICE_RETRY_DELAY_MINUTES,
  };
}

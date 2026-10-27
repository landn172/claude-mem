/**
 * Constant-time bearer comparison, same digest trick as the sync hub's
 * static mode: hashing both sides first normalizes length so
 * timingSafeEqual never throws on mismatched sizes.
 */

const encoder = new TextEncoder();

export async function secretsMatch(presented: string, configured: string): Promise<boolean> {
	const [presentedDigest, configuredDigest] = await Promise.all([
		crypto.subtle.digest("SHA-256", encoder.encode(presented)),
		crypto.subtle.digest("SHA-256", encoder.encode(configured)),
	]);
	return crypto.subtle.timingSafeEqual(presentedDigest, configuredDigest);
}

/** Extract a Bearer token from the Authorization header ("" when absent). */
export function bearerToken(request: Request): string {
	const header = request.headers.get("Authorization") ?? "";
	return header.startsWith("Bearer ") ? header.slice("Bearer ".length).trim() : "";
}

/** True when the request carries the configured secret. Fail-closed on empty config. */
export async function authorized(request: Request, configured: string | undefined): Promise<boolean> {
	const secret = (configured ?? "").trim();
	if (secret.length === 0) return false;
	const presented = bearerToken(request);
	if (presented.length === 0) return false;
	return secretsMatch(presented, secret);
}

import { NextResponse } from "next/server";
import { authorizeUrl, oidcConfig, pkceChallenge, randomToken } from "@/lib/oidc";
import { esaLinkAllowed } from "@/lib/esa-link-rule";
import { FLOW_COOKIE, flowCookieOptions, safeNext, type FlowState } from "@/lib/oidc-flow";

// Начало входа через ЕСА.
//
// Два режима, и выбирает их не параметр, а факт сессии:
//  - гость → `login`: после возврата ищем пользователя по `sub`;
//  - вошедший → `link`: после возврата привязываем `sub` к ЕГО учётке.
//
// Незнакомый `sub` в режиме `login` создаёт посетителя (роль `user`) — решение владельца
// 2026-09-02. Персонал, вошедший паролем, привязывает свой `sub` в режиме `link`, иначе
// первый вход через ЕСА завёл бы ему второй, посетительский аккаунт.

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const cfg = oidcConfig();
  if (!cfg) return new NextResponse("Not Found", { status: 404 });

  let mode: FlowState["mode"] = "login";
  let userId: number | undefined;
  try {
    const { getPayload } = await import("payload");
    const { default: config } = await import("@payload-config");
    const payload = await getPayload({ config });
    const { user } = await payload.auth({ headers: request.headers });
    // `link` — только персоналу (`lib/esa-link-rule.ts`): режим не привязывает
    // `sub`, а сливает две учётки, переносит владение карточками и удаляет посетительскую
    // оболочку. Посетителю с живой сессией раньше выдавался именно он, и этого было
    // достаточно, чтобы снести чужую учётку мимо всех гейтов (аудит write-authz, 2026-09-30).
    if (user && esaLinkAllowed((user as { role?: string }).role)) {
      mode = "link";
      userId = Number(user.id);
    }
  } catch {
    // Сломанная сессия — это гость.
  }

  const verifier = randomToken(48);
  const flow: FlowState = {
    state: randomToken(),
    nonce: randomToken(),
    verifier,
    mode,
    userId,
    next: safeNext(new URL(request.url).searchParams.get("next")),
  };

  let target: string;
  try {
    target = await authorizeUrl(cfg, {
      state: flow.state,
      nonce: flow.nonce,
      codeChallenge: await pkceChallenge(verifier),
    });
  } catch {
    return new NextResponse("Единый вход сейчас недоступен. Попробуйте позже.", {
      status: 502,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  }

  const res = NextResponse.redirect(target, 302);
  res.cookies.set(FLOW_COOKIE, JSON.stringify(flow), flowCookieOptions(request));
  return res;
}

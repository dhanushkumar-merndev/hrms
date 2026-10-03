import { MAINTENANCE_SECRET } from "../_shared/env.ts";
import { ipHash, serve } from "../_shared/http.ts";
import { rpc } from "../_shared/supabase.ts";
import { createPublicConfigHandler, type LoginSupportLookup } from "./handler.ts";

const handler = createPublicConfigHandler({
  hashIp: (req) => ipHash(req, MAINTENANCE_SECRET),
  lookup: (orgCode, hashedIp) => rpc<LoginSupportLookup>("internal_login_support", {
    p_org_code: orgCode,
    p_ip_hash: hashedIp,
  }),
});

if (import.meta.main) serve(handler);

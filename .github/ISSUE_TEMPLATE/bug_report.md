# Bug report

<!--
Short on purpose. Everything here is something only you can supply; everything else we can work out
from the repository. If a field does not apply, say "not applicable" rather than deleting it: a missing
field is a question we will have to ask back.

Do not report a security problem here. SECURITY.md says where to send those.
-->

**What you expected**

<!-- One or two sentences. What did you think would happen? -->

**What happened**

<!-- What did you see instead? -->

**Version**

<!-- The `default_version` in pg_bloat_cause.control, or the tag you installed. -->

**PostgreSQL version and platform**

<!-- `SELECT version();` is enough. Managed instances are worth naming: RDS, Aurora and other hosted
    platforms differ from a self-managed server, and this tool names the cause of dead rows not being cleaned up. -->

**Output of `SELECT * FROM bloat_cause_text()`**

<!--
Usually answers the question on its own, and it is safe to paste: the text form is what an operator
would be shown. Run it as the role you would use, not as a superuser, so we see what you actually see.
-->

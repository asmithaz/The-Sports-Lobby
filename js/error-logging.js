// Captures uncaught JS errors and unhandled promise rejections and
// writes them to the `error_logs` table (see supabase/error-logs-schema.sql).
// Write-only from the client — logs are only readable via the Supabase
// dashboard or service role, never by other users.
(function () {
    async function reportError(message, stack) {
        if (!window.supabase) return;

        let userId = null;
        try {
            const { data } = await supabase.auth.getSession();
            userId = data && data.session ? data.session.user.id : null;
        } catch (e) {}

        try {
            await supabase.from('error_logs').insert({
                user_id: userId,
                message: message,
                stack: stack || null,
                url: window.location.href,
                user_agent: navigator.userAgent
            });
        } catch (e) {}
    }

    window.addEventListener('error', function (event) {
        reportError(event.message, event.error && event.error.stack);
    });

    window.addEventListener('unhandledrejection', function (event) {
        const reason = event.reason;
        reportError(
            reason && reason.message ? reason.message : String(reason),
            reason && reason.stack
        );
    });
})();

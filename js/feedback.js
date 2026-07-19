// Feedback modal, opened from the "Feedback" link in the shared site
// footer. Writes to the `feedback` table (see supabase/feedback-schema.sql).
// Write-only from the client — submissions are only readable via the
// Supabase dashboard or service role, never by other users.
(function () {
    var modal = null;

    function injectStyles() {
        if (document.getElementById('feedback-widget-styles')) return;
        var style = document.createElement('style');
        style.id = 'feedback-widget-styles';
        style.textContent =
            '.feedback-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.6); ' +
            'display: flex; align-items: center; justify-content: center; z-index: 1000; padding: var(--space-4); }' +
            '.feedback-panel { background: var(--c-surface); border: 1px solid var(--c-border); ' +
            'border-radius: var(--radius-lg); padding: var(--space-6); width: 100%; max-width: 420px; ' +
            'font-family: var(--font); color: var(--c-text-primary); }' +
            '.feedback-panel h3 { margin: 0 0 var(--space-3); font-size: var(--text-lg); font-weight: var(--weight-bold); }' +
            '.feedback-panel textarea { width: 100%; min-height: 120px; background: var(--c-surface-2); ' +
            'color: var(--c-text-primary); border: 1px solid var(--c-border); border-radius: var(--radius-md); ' +
            'padding: var(--space-3); font-family: var(--font); font-size: var(--text-base); resize: vertical; box-sizing: border-box; }' +
            '.feedback-panel textarea:focus { outline: none; border-color: var(--c-accent-border); }' +
            '.feedback-actions { display: flex; justify-content: flex-end; gap: var(--space-2); margin-top: var(--space-4); }' +
            '.feedback-actions button { font-family: var(--font); font-size: var(--text-base); border-radius: var(--radius-md); ' +
            'padding: var(--space-2) var(--space-4); cursor: pointer; border: 1px solid var(--c-border); background: transparent; color: var(--c-text-secondary); }' +
            '.feedback-actions button.feedback-submit { background: var(--c-accent-dim); border-color: var(--c-accent-border); color: var(--c-accent); }' +
            '.feedback-actions button:disabled { opacity: 0.5; cursor: default; }' +
            '.feedback-error { color: var(--c-danger); font-size: var(--text-sm); margin-top: var(--space-2); }' +
            '.feedback-success { text-align: center; padding: var(--space-4) 0; }';
        document.head.appendChild(style);
    }

    function closeModal() {
        if (modal) {
            modal.remove();
            modal = null;
        }
    }

    async function submitFeedback(message, panel) {
        let userId = null;
        try {
            const { data } = await supabase.auth.getSession();
            userId = data && data.session ? data.session.user.id : null;
        } catch (e) {}

        await supabase.from('feedback').insert({
            user_id: userId,
            message: message,
            page_url: window.location.href,
            user_agent: navigator.userAgent
        });

        panel.innerHTML = '<div class="feedback-success">' +
            '<h3>Thanks!</h3><p>Your feedback was sent.</p></div>';
        setTimeout(closeModal, 1500);
    }

    function openModal() {
        if (modal || !window.supabase) return;
        injectStyles();

        modal = document.createElement('div');
        modal.className = 'feedback-overlay';
        modal.addEventListener('click', function (e) {
            if (e.target === modal) closeModal();
        });

        const panel = document.createElement('div');
        panel.className = 'feedback-panel';
        panel.innerHTML =
            '<h3>Send Feedback</h3>' +
            '<textarea placeholder="Found a bug, or something feel off? Let us know."></textarea>' +
            '<div class="feedback-actions">' +
            '<button type="button" class="feedback-cancel">Cancel</button>' +
            '<button type="button" class="feedback-submit">Send</button>' +
            '</div>';

        modal.appendChild(panel);
        document.body.appendChild(modal);

        const textarea = panel.querySelector('textarea');
        const submitBtn = panel.querySelector('.feedback-submit');
        const cancelBtn = panel.querySelector('.feedback-cancel');

        textarea.focus();
        cancelBtn.addEventListener('click', closeModal);
        submitBtn.addEventListener('click', async function () {
            const message = textarea.value.trim();
            if (!message) return;
            submitBtn.disabled = true;
            cancelBtn.disabled = true;
            try {
                await submitFeedback(message, panel);
            } catch (e) {
                const err = document.createElement('div');
                err.className = 'feedback-error';
                err.textContent = "Couldn't send feedback — please try again.";
                panel.appendChild(err);
                submitBtn.disabled = false;
                cancelBtn.disabled = false;
            }
        });
    }

    document.addEventListener('DOMContentLoaded', function () {
        document.querySelectorAll('[data-feedback-trigger]').forEach(function (el) {
            el.addEventListener('click', function (e) {
                e.preventDefault();
                openModal();
            });
        });
    });
})();

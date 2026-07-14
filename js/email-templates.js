// Shared branding wrapper for all transactional emails sent via the
// send-email Edge Function. Edit this file to change how every email
// looks — callers only ever supply a title and a body snippet.
function wrapEmail(title, bodyHtml) {
    return `
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0f1117;padding:32px 16px;">
        <div style="max-width:480px;margin:0 auto;background:#1a1d27;border:1px solid rgba(255,255,255,0.08);border-radius:10px;overflow:hidden;">
            <div style="padding:20px 28px;border-bottom:1px solid rgba(255,255,255,0.08);">
                <span style="font-size:13px;font-weight:700;letter-spacing:0.08em;color:#4ade80;text-transform:uppercase;">The Sports Lobby</span>
            </div>
            <div style="padding:28px;">
                <h1 style="font-size:20px;font-weight:700;margin:0 0 16px 0;color:#f0f0f2;">${title}</h1>
                <div style="font-size:14px;line-height:1.6;color:#8b8fa8;">${bodyHtml}</div>
            </div>
            <div style="padding:16px 28px;border-top:1px solid rgba(255,255,255,0.08);font-size:12px;color:#555870;">
                2026 The Sports Lobby. All rights reserved.
            </div>
        </div>
    </div>`;
}

// Shared button used inside email bodies.
function emailButton(href, label) {
    return `<a href="${href}" style="display:inline-block;margin-top:8px;padding:10px 20px;background:#4ade80;color:#0f1117;font-weight:700;font-size:14px;text-decoration:none;border-radius:6px;">${label}</a>`;
}

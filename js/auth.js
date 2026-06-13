async function isLoggedIn() {
    const { data: { session } } = await supabase.auth.getSession();
    return session !== null;
}

async function logout() {
    await supabase.auth.signOut();
    window.location.href = '/index.html';
}

async function renderDashboardLink() {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) return;

    const link = document.createElement('a');
    link.href = '/dashboard/';
    link.textContent = '← Dashboard';
    link.className = 'dashboard-return-link';
    link.style.cssText =
        'position:fixed;top:14px;right:20px;z-index:1000;padding:8px 16px;' +
        'background-color:#151F30;color:#fff;font-weight:bold;font-family:Arial,Helvetica,sans-serif;' +
        'text-decoration:none;border-radius:8px;box-shadow:0 2px 6px rgba(0,0,0,0.15);transition:background-color 0.3s;';
    link.onmouseenter = () => { link.style.backgroundColor = '#4d63dd'; };
    link.onmouseleave = () => { link.style.backgroundColor = '#151F30'; };
    document.body.appendChild(link);
}

async function startLeague(setupUrl) {
    const loggedIn = await isLoggedIn();
    if (loggedIn) {
        window.location.href = setupUrl;
    } else {
        sessionStorage.setItem('sp_redirect_after_login', setupUrl);
        window.location.href = '/login/index.html';
    }
}
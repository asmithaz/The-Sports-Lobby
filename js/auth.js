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
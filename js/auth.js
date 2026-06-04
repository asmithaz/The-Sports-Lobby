async function isLoggedIn() {
    const { data: { session } } = await supabase.auth.getSession();
    return session !== null;
}

async function logout() {
    await supabase.auth.signOut();
    window.location.href = '/index.html';
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
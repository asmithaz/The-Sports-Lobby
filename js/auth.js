async function isLoggedIn() {
    const { data: { session } } = await supabase.auth.getSession();
    return session !== null;
}

async function logout() {
    await supabase.auth.signOut();
    window.location.href = '/index.html';
}

async function renderNav() {
    const { data: { session } } = await supabase.auth.getSession();
    const navLinks = document.querySelector('.nav-links');
    if (!navLinks) return;

    if (session) {
        navLinks.querySelectorAll('a').forEach(a => {
            const href = a.getAttribute('href') || '';
            const text = a.textContent.trim();
            if (href.includes('/login/') || text === 'Login' || text === 'Signup' || text === 'Sign Up') {
                a.remove();
            }
        });

        const dashboard = document.createElement('a');
        dashboard.href = '/dashboard/';
        dashboard.className = 'nav-link';
        dashboard.textContent = 'Dashboard';
        navLinks.appendChild(dashboard);

        const account = document.createElement('a');
        account.href = '/account/';
        account.className = 'nav-link';
        account.textContent = 'Account';
        navLinks.appendChild(account);

        const logoutLink = document.createElement('a');
        logoutLink.href = '#';
        logoutLink.className = 'nav-link';
        logoutLink.textContent = 'Logout';
        logoutLink.addEventListener('click', e => { e.preventDefault(); logout(); });
        navLinks.appendChild(logoutLink);
    }
}

document.addEventListener('DOMContentLoaded', renderNav);

async function startLeague(setupUrl) {
    const loggedIn = await isLoggedIn();
    if (loggedIn) {
        window.location.href = setupUrl;
    } else {
        sessionStorage.setItem('sp_redirect_after_login', setupUrl);
        window.location.href = '/login/index.html';
    }
}

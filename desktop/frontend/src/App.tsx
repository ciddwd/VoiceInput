import {useEffect, useState} from 'react';
import './App.css';
import {getLocale, setLocale, t, useLocale} from './i18n';
import {ErrorBoundary} from './ErrorBoundary';
import {AdbPage} from './pages/AdbPage';
import {DashboardPage} from './pages/DashboardPage';
import {DictionaryPage} from './pages/DictionaryPage';
import {SnippetsPage} from './pages/SnippetsPage';

type Tab = 'dashboard' | 'snippets' | 'dictionary' | 'adb';
type Theme = 'auto' | 'light' | 'dark';

const THEME_KEY = 'voiceinput.theme';

function readTheme(): Theme {
    const v = localStorage.getItem(THEME_KEY);
    return v === 'light' || v === 'dark' ? v : 'auto';
}

function applyTheme(t: Theme) {
    const root = document.documentElement;
    if (t === 'auto') root.removeAttribute('data-theme');
    else root.setAttribute('data-theme', t);
}

function App() {
    const [tab, setTab] = useState<Tab>('dashboard');
    const [theme, setTheme] = useState<Theme>(readTheme);
    const locale = useLocale();

    useEffect(() => { applyTheme(theme); localStorage.setItem(THEME_KEY, theme); }, [theme]);

    const cycleTheme = () => setTheme(t => t === 'auto' ? 'light' : t === 'light' ? 'dark' : 'auto');
    const cycleLang = () => setLocale(getLocale() === 'zh' ? 'en' : 'zh');

    return (
        <div className="page">
            <header className="topbar">
                <div className="brand">VoiceInput</div>
                <nav className="tabs">
                    <button className={`tab ${tab === 'dashboard' ? 'tab-on' : ''}`}
                            onClick={() => setTab('dashboard')}>{t('nav.dashboard')}</button>
                    <button className={`tab ${tab === 'snippets' ? 'tab-on' : ''}`}
                            onClick={() => setTab('snippets')}>{t('nav.snippets')}</button>
                    <button className={`tab ${tab === 'dictionary' ? 'tab-on' : ''}`}
                            onClick={() => setTab('dictionary')}>{t('nav.dictionary')}</button>
                    <button className={`tab ${tab === 'adb' ? 'tab-on' : ''}`}
                            onClick={() => setTab('adb')}>{t('nav.adb')}</button>
                </nav>
                <div className="topbar-spacer"/>
                <button
                    className="icon-btn"
                    onClick={cycleLang}
                    title={t('lang.tooltip', locale === 'zh' ? '中文' : 'English')}
                    aria-label="Switch language">
                    <span style={{fontSize: 12, fontWeight: 600, fontFamily: 'inherit'}}>
                        {locale === 'zh' ? '中' : 'EN'}
                    </span>
                </button>
                <button
                    className="icon-btn"
                    onClick={cycleTheme}
                    title={t('theme.tooltip', theme)}
                    aria-label="Toggle theme">
                    {theme === 'light' ? <IconSun/> : theme === 'dark' ? <IconMoon/> : <IconAuto/>}
                </button>
            </header>
            <ErrorBoundary key={tab}>
                {tab === 'dashboard' && <DashboardPage/>}
                {tab === 'snippets' && <SnippetsPage/>}
                {tab === 'dictionary' && <DictionaryPage/>}
                {tab === 'adb' && <AdbPage/>}
            </ErrorBoundary>
        </div>
    );
}

function IconSun() {
    return (
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="12" cy="12" r="4"/>
            <path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6l1.4 1.4M17 17l1.4 1.4M5.6 18.4l1.4-1.4M17 7l1.4-1.4"/>
        </svg>
    );
}

function IconMoon() {
    return (
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
            <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>
        </svg>
    );
}

function IconAuto() {
    return (
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="12" cy="12" r="9"/>
            <path d="M12 3a9 9 0 0 0 0 18z" fill="currentColor"/>
        </svg>
    );
}

export default App;

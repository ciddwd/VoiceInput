// Tiny key→{en, zh} translator. No external dep — the app's vocabulary is
// small enough that a flat dictionary stays maintainable, and avoiding
// react-i18next saves ~30KB of bundle.
//
// Use:
//     import {t, useLocale} from './i18n';
//     const locale = useLocale();              // re-renders on change
//     return <button>{t('common.save')}</button>;

import {useEffect, useState} from 'react';

export type Locale = 'en' | 'zh';

const LOCALE_KEY = 'voiceinput.locale';

const dict: Record<string, Record<Locale, string>> = {
    // --- top nav -------------------------------------------------
    'nav.dashboard':  {en: 'Dashboard',  zh: '面板'},
    'nav.snippets':   {en: 'Snippets',   zh: '备选库'},
    'nav.dictionary': {en: 'Dictionary', zh: '词典'},
    'nav.adb':        {en: 'ADB',        zh: '无线调试'},

    // --- adb wireless debugging page ----------------------------
    'adb.title':         {en: 'Wireless ADB',                       zh: '无线 ADB 调试'},
    'adb.sub':           {en: 'Open "Wireless debugging" on your phone — discoverable endpoints appear below.',
                          zh: '在手机打开「无线调试」即可看到下方设备。配对端口仅在「使用配对码配对设备」弹窗打开时出现。'},
    'adb.adbVersion':    {en: 'adb binary',                          zh: 'adb 版本'},
    'adb.adbMissing':    {en: 'adb not found on PATH',                zh: '未在 PATH 找到 adb，请安装 platform-tools'},
    'adb.pairingFound':  {en: 'Pairing endpoint',                     zh: '待配对端点'},
    'adb.connectFound':  {en: 'Debug endpoint',                       zh: '调试端点'},
    'adb.noPairing':     {en: 'No pairing endpoint — tap "Pair device with pairing code" on the phone.',
                          zh: '没发现配对端点。请在手机「无线调试 → 使用配对码配对设备」打开弹窗。'},
    'adb.noConnect':     {en: 'No debug endpoint — make sure Wireless debugging is on.',
                          zh: '没发现调试端点。确认无线调试已开启。'},
    'adb.pairingCode':   {en: '6-digit pairing code',                 zh: '6 位配对码'},
    'adb.btnPair':       {en: 'Pair',                                 zh: '配对'},
    'adb.btnConnect':    {en: 'Connect',                              zh: '连接'},
    'adb.btnDisconnect': {en: 'Disconnect',                           zh: '断开'},
    'adb.btnRefresh':    {en: 'Refresh devices',                      zh: '刷新设备列表'},
    'adb.btnCopy':       {en: 'Copy',                                 zh: '复制'},
    'adb.copied':        {en: 'Copied',                               zh: '已复制'},
    'adb.devicesTitle':  {en: 'Connected devices (adb devices -l)',   zh: '已连接设备 (adb devices -l)'},
    'adb.noDevices':     {en: 'No devices yet.',                      zh: '暂无设备。'},
    'adb.pairOk':        {en: 'Paired. Now click Connect on the debug endpoint.',
                          zh: '配对成功。现在点调试端点的「连接」即可。'},

    'theme.tooltip':  {en: 'Theme: {0} (click to cycle)', zh: '主题：{0}（点击切换）'},
    'lang.tooltip':   {en: 'Language: {0}',                zh: '语言：{0}'},

    // --- common verbs -------------------------------------------
    'common.save':     {en: 'Save',     zh: '保存'},
    'common.saving':   {en: 'Saving…',  zh: '保存中…'},
    'common.cancel':   {en: 'Cancel',   zh: '取消'},
    'common.delete':   {en: 'Delete',   zh: '删除'},
    'common.edit':     {en: 'Edit',     zh: '编辑'},
    'common.add':      {en: 'Add',      zh: '添加'},
    'common.new':      {en: '+ New',    zh: '+ 新建'},

    // --- dashboard ----------------------------------------------
    'dash.listening':     {en: 'Listening',         zh: '监听中'},
    'dash.idle':          {en: 'Idle',              zh: '空闲'},
    'dash.connected':     {en: 'Connected',         zh: '已连接'},
    'dash.pairing':       {en: 'Pairing…',          zh: '配对中…'},
    'dash.awaitingAuth':  {en: 'Awaiting auth',     zh: '等待认证'},
    'dash.locked':        {en: 'Locked',            zh: '已锁定'},
    'dash.endpoint':      {en: 'Endpoint',          zh: '地址'},
    'dash.lanIps':        {en: 'LAN IPs',           zh: '局域网 IP'},
    'dash.mdns':          {en: 'mDNS',              zh: 'mDNS'},
    'dash.device':        {en: 'Device',            zh: '设备'},
    'dash.foreground':    {en: 'Foreground',        zh: '前台应用'},
    'dash.forgetDevices': {en: 'Forget all devices',zh: '清除所有配对设备'},
    'dash.confirmForget': {en: 'Forget all paired devices? They will need to re-enter the PIN.',
                           zh: '确认清除所有已配对的设备？下次需要重新输入 PIN。'},
    'dash.inbound':       {en: 'Inbound',           zh: '收到的消息'},
    'dash.eventsOne':     {en: '1 event',           zh: '1 条'},
    'dash.eventsMany':    {en: '{0} events',        zh: '{0} 条'},
    'dash.emptyLog':      {en: 'Waiting for the mobile keyboard to send text…',
                           zh: '等待手机端发送文字…'},

    // --- pairing modal ------------------------------------------
    'pair.title':         {en: 'Pair a new device',  zh: '配对新设备'},
    'pair.subPrefix':     {en: ' is requesting access. ',
                           zh: ' 正在请求访问。'},
    'pair.subBody':       {en: 'Enter this PIN on the phone to allow it.',
                           zh: '在手机端输入下面的 PIN 即可允许连接。'},
    'pair.foot':          {en: 'PIN is valid for 5 minutes. 3 wrong attempts will lock the device for 60 seconds.',
                           zh: 'PIN 5 分钟内有效，连续 3 次错误将锁定 60 秒。'},

    // --- snippets page ------------------------------------------
    'snip.categories':       {en: 'Categories',                            zh: '分类'},
    'snip.noCategories':     {en: 'No categories yet',                     zh: '还没有分类'},
    'snip.pickCategory':     {en: 'Pick or create a category on the left.',zh: '在左侧选择或新建一个分类。'},
    'snip.noSnippets':       {en: 'No snippets in this category.',         zh: '该分类下没有备选项。'},
    'snip.newSnippet':       {en: '+ Snippet',                             zh: '+ 备选项'},
    'snip.editCategory':     {en: 'Edit category',                         zh: '编辑分类'},
    'snip.confirmDelCat':    {en: 'Delete this category and all its snippets?',
                              zh: '删除该分类及其下全部备选项？'},
    'snip.confirmDelSnip':   {en: 'Delete this snippet?',                  zh: '删除该备选项？'},
    'snip.matchesPrefix':    {en: '/ matches ',                            zh: '/ 匹配 '},

    // --- snippet editor ----------------------------------------
    'snip.newCategoryTitle': {en: 'New category',                          zh: '新建分类'},
    'snip.editCategoryTitle':{en: 'Edit {0}',                              zh: '编辑 {0}'},
    'snip.fieldName':        {en: 'Name',                                  zh: '名称'},
    'snip.fieldPrefix':      {en: 'Prefix (auto-prepended to every send)', zh: '前缀（每次发送时自动加在开头）'},
    'snip.fieldSuffix':      {en: 'Suffix (auto-appended)',                zh: '后缀（每次发送时自动加在末尾）'},
    'snip.fieldSendKey':     {en: 'Default send-suffix key',               zh: '默认发送结束键'},
    'snip.fieldRegex':       {en: 'Auto-select when focused app matches regex',
                              zh: '当前台应用匹配此正则时自动切到本分类'},
    'snip.fieldLabel':       {en: 'Label (shown on the chip)',             zh: '标签（显示在 chip 上）'},
    'snip.fieldContent':     {en: 'Content (inserted on tap)',             zh: '内容（点击时插入）'},
    'snip.newSnippetTitle':  {en: 'New snippet',                           zh: '新建备选项'},
    'snip.editSnippetTitle': {en: 'Edit "{0}"',                            zh: '编辑「{0}」'},

    // --- dictionary --------------------------------------------
    'dict.title':       {en: 'Dictionary · hotwords', zh: '词典 · 热词'},
    'dict.subOne':      {en: '1 term.',               zh: '1 个词。'},
    'dict.subMany':     {en: '{0} terms.',            zh: '{0} 个词。'},
    'dict.subTail':     {en: 'Preserved verbatim by polish & ASR.',
                         zh: '润色和 ASR 都会原样保留这些词。'},
    'dict.placeholderEmpty': {en: 'Type a term + Enter…', zh: '输入一个词后回车…'},
    'dict.placeholderMore':  {en: 'Add another…',         zh: '继续添加…'},
    'dict.help': {en: 'Press Enter / comma to add. Press Backspace on an empty field to remove the last term. Examples: proper nouns, project codenames, brand spelling, technical jargon.',
                  zh: '回车 / 逗号添加；输入框空时按退格删除最后一个。例如：人名、项目代号、品牌写法、专业术语。'},
};

let current: Locale = (() => {
    const v = typeof localStorage !== 'undefined' ? localStorage.getItem(LOCALE_KEY) : null;
    if (v === 'en' || v === 'zh') return v;
    // Auto-pick from navigator language (zh by default for this user base).
    if (typeof navigator !== 'undefined' && navigator.language?.startsWith('en')) return 'en';
    return 'zh';
})();

const listeners = new Set<() => void>();

export function t(key: string, ...args: (string | number)[]): string {
    const entry = dict[key];
    if (!entry) return key; // fall back to key so missing translations are obvious
    let s = entry[current] ?? entry.en ?? key;
    args.forEach((v, i) => { s = s.replace(`{${i}}`, String(v)); });
    return s;
}

export function setLocale(l: Locale) {
    if (current === l) return;
    current = l;
    try { localStorage.setItem(LOCALE_KEY, l); } catch (_) {}
    listeners.forEach((fn) => fn());
}

export function getLocale(): Locale { return current; }

export function useLocale(): Locale {
    const [, force] = useState(0);
    useEffect(() => {
        const fn = () => force((n) => n + 1);
        listeners.add(fn);
        return () => { listeners.delete(fn); };
    }, []);
    return current;
}

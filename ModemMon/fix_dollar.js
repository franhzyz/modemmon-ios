// Swift: убрать невалидные \$ в строке скрипта клиентов
const fs = require('fs');
let t = fs.readFileSync('MiscViews.swift', 'utf8');
const needle = t.match(/let script = "echo \\"\\[leases\]\\"[\s\S]*?exit 0/);
if (!needle) { console.log('script line not found'); process.exit(1); }
let s = needle[0];
// внутри Swift-строки: \\(одна косая) + \$ -> просто $ (Swift $ не спецсимвол, shell в одинарных кавычках awk не расширяет)
s = s.replace(/\\\\\$/g, '$');
t = t.replace(needle[0], s);
fs.writeFileSync('MiscViews.swift', t);
console.log('fixed:', !t.includes('\\\\$'));

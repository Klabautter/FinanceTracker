More banks connect cleanly, currency exchanges no longer count as spending, and the app reminds you before a bank's access expires.

- **Banks that share no accounts:** With a personal Enable Banking application, a bank only shares accounts you linked in its control panel. If a bank returns none, the app now explains how to link it and offers "Erneut verbinden" instead of showing an empty connection as connected. The bank list mentions this up front.
- **More banks readable:** Banks that send debits with a minus sign, such as Trade Republic, no longer fail the whole fetch. If a booking still cannot be read, the log names the field.
- **Currency exchanges:** Exchanging money between your own currency accounts of one bank (for example "Exchanged to SEK" at Revolut) counts as a transfer, not as spending and income. Existing bookings are corrected on the next start.
- **Account names:** Several currency accounts of one bank are named by their currency, for example "Revolut EUR" and "Revolut SEK".
- **Hide accounts:** Accounts you no longer use can be hidden from the account list in the account editor. They stay available in a collapsed group, and their balance and bookings are unchanged.
- **Bank access expiring:** With notifications turned on, macOS reminds you seven days before and on the day a bank's access expires, even when the app is closed. After you renew it, the app continues from the last fetch instead of loading the bank's whole history again.
- **Smaller fixes:** The redirect URL check no longer warns after a completed bank login.

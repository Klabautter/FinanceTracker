Fixes a problem in 0.5.3 that could remove the Enable Banking key after a restart.

- **Enable Banking key:** 0.5.3 moved the key to the modern keychain but then removed the new copy together with the old one, so after a restart bank refreshes failed with missing credentials. The move now keeps the new copy. If bank refresh stopped working after 0.5.3, load your Enable Banking key file once more under Konten → Datenquelle hinzufügen → Bankkonto verbinden; your bank connections stay as they are.

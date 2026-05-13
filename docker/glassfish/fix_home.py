import re

fname = '/tmp/war-patch/secured/Home.jspx'
with open(fname) as f:
    c = f.read()

# Replace FortressAllowed permission checks with role checks (no LDAP perms needed)
c = re.sub(
    r'visible="#{FortressAllowed\[\'[^\']+:Admin\'\]}"',
    "visible=\"#{FortressUserInRole['Admin']}\"",
    c
)
c = re.sub(
    r'visible="#{FortressAllowed\[\'[^\']+:Normal\'\]}"',
    "visible=\"#{FortressUserInRole['NormalUser']}\"",
    c
)

with open(fname, 'w') as f:
    f.write(c)

print("Home.jspx: FortressAllowed replaced with FortressUserInRole")

Wyseman is a database schema manager, part of the WyattERP application 
framework.

It is used for authoring and managing database schemas in PostgreSQL.  It 
also provides run-time access to the data dictionary for databases it manages.

Wyseman was originally implemented entirely in Tcl/Tk.  More recently,
the command line app was ported to ruby.  However, the configuration
code (i.e. the way you describe your database sql and schema objects) remains 
in Tcl, which is a good fit for the long term.

The run-time code has been partially ported to ruby--at least enough to
work for basic purposes.  More work could be done here as demand arises.

Also a Javascript run-time has been created to act as a server end for Wylib
applications running in the browser.

See README.orig for more on the original project description.
See README.pg for notes on installing/interfacing with PostgreSQL.

For now, you may have to consult the source code for command line options
for the ruby script.
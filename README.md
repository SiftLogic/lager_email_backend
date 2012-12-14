lager_email_backend
===================

Backend for Lager which sends emails at configured error levels and
other nice stuff.  The most important feature being that multiple
messages of the same type are sent as a single email every minute.

The backend still contains some SiftLogic specific configuration.

The first is ignore_error/1 which is a list of patterns for which no
email is generated.  Usually because of bugs in other people's code.
We believe that this list is good also for general usage, but feel
free to customize to your local situation.

The second is that we use our own log wrapper (slog.erl, included) and
messages are gathered together based on the output format of that
module.  It usually works for the default format too, but not as well.

To activate the backend put something like

      {lager_email_backend,
       [{level, warning},
        {name, email_ops},
        {from, "noreply@example.com"},
        {recipients, ["somedude@example.com", "someotherdude@example.com"]},
        {opts, [{relay, "localhost"}, {port, 26}]}]}

with your lager handlers.

Hoping it will be as useful to you as it has been to us.

Patches welcome.

# FollowUp Engine (aka FUE)
preface: i work for Ytel and developed a version 1 of this that did nothing more than post call counts to a php script. i then spent a few months in my spare time writing this massive upgrade. this is in no way officially supported by Ytel, however they have allowed me to open source it, and if i can keep adding features i will. it is currently used in production systems.

the first section of this document is the overall layout and how to use the system, installing is at the bottom :)

## the basics
FUE uses the [Ytel API](https://ytel.com) to send sms, ringless voicemails, and emails. it also can send generic API requests. all based on call counts.

the system first gathers a list of all actions that will need to be matched on, things like call count, status, campaign, and list. then it gets a list of leads in the last 10 minutes that were modified (this is dependent on what your interval is set to).

once it has a list of numbers it then sends them to the carrier lookup api and gets details like zipcodes, state, if its wireless, and a few other things. it then uses this information to match it against a template, and then fires it off.

**WARNING** this requires an API account from https://ytel.com its free to sign up, and is pay as you go. the script will not run unless you have a valid accountSID and accountToken. because FUE needs detailed information about a number, its required that a carrier lookup is performed which is a small fee, this data is cached for i believe 30 days, and is refreshed to prevent stale information. i also lookup the source numbers you plan on using, which is also the same charge, however these are looked up only once.

### decisioning  
the system will make a decision based on various factors of your choosing. they encompass all templates, and specific templates. these templates contain the action to be taken for a specific call count.

#### ytel_settings table:

##### global settings
FUE has a set of global filters, these filters cover all templates and can help with compliance requirements. one thing to note is the system has a hard coded DNC and DNCL status set. it will always include those two statuses.

this table contains the global settings for FUE. at minimum you'll need to supply the following fields.

* accountSID
* accountToken

you also can setup the test mode which sends all the actions to a number and email of your choice.

* testMode - 1 to turn on, 0 to turn off
* testEmail
* testPhone

misc settings:

* runInterval - how often to run (lowest every minute)
* runWindow - between which hours to run at

the global filters are as follows

* excludedStatuses - exclude statuses from all templates, DNC and DNCL is always included.
* includedLists - include a comma separated list globally
* excludedCarriers - block by remote carrier


#### ytel_followup_templates table

##### per template filtering
each template can have its own set of filtering rules. first and foremost however is all templates are based off of one thing... call counts. this is the main trigger for a template.

you can filter templates based on theses fields.

* callCount - X
* includedCampaigns - 1000,ACCID
* includedStatuses - 'AA','AB','ADC','AFTHRS','AL','DROP','TIMEOT','VMAIL','WRADD','B'
* includedLists - 998,999,2000


##### template field requirements  
below is a breakdown of required fields for each template type, and what each available option is.

* callCount
* type
  * sms
  * email
  * email-html
  * rvm
  * api
* fromPrimary
  * sms - From number that is sms enabled
  * email - Verified email address
  * rvm - First number
* fromAlternate
  * email - Used as the display from name in the email
  * rvm - Second number used for rvm
* Subject
  * Email - Subject of the email
  * Api
    * get (default if none is chosen)
    * post
* Body
  * sms - Body of the sms message
  * email-html - Html text for email
  * email - Text email, no html
* bodyUrl
  * rvm - The audio file to be played.
  * Api - Url to post to, will accept template variables.
* active
  * 0 - disabled (should be disabled by default so the customer has to turn it on after checking it)
  * 1 - enabled
* includedStatuses - Used to tie a specific template to a specific status only.

all other fields are optional


##### lead, and custom data in templates.
these are the variables that are available in the body or body url. it is searched and replaced with any matching data found. all data is gathered from the vicidial_list table.

* <--first_name-->
* <--last_name-->
* <--address1-->
* <--address2-->
* <--address3-->
* <--city-->
* <--state-->
* <--postal_code-->
* <--phone_number-->
* <--email-->
* <--lead_id-->
* <--list_id-->
* <--campaignID-->
* <--outboundCID--> ( phone number last used to call customer)
* <--+1m--> ( takes the current time and adds x number of minutes to it )
* <--+1h--> ( takes the current time and adds x number of hours to it )
* <--custom_column_name--> ( reads custom_1234 for example and looks at the column names, may not apply)

alternate custom data:
you can also include an alternate replacement when one doesn't exist, say.

```
hello, <--first_name-->, it was great to meet you
```

if the lead doesn't have a first name it will end up being blank which can be fine for some cases however you can do something like this.

```
hello, <--first_name::friend-->, it was great to meet you.
```

in this case it will replace first_name with friend only if there is no associated lead data.


#### template examples.
templates can be mix and matched for the same call counts, and types. the below section will cover each in detail and cover a broad use case. each template can be refined by status, list, campaign and a few others, some of these examples will include that some will not to save on typing. if you don't specify a one of those fields its a wildcard match.

##### SMS
| callCount | type | fromPrimary | body | active | includedStatuses | includedLists |
| --|-----|------------|-------------------------|---|-----------|----------|
| 1 | sms | 7145551212 | hello, <--first_name--> | 1 | 'AA','AB' | 998,1000 |
| 1 | sms | 9495551212 | hello, <--first_name--> | 1 | 'AA','AB' | 998,1000 |
| 1 | sms | 3105551212 | hello, <--first_name--> | 1 | 'AA','AB' | 998,1000 |

in the example above, the system will see for call count 1, that a text message should be sent, because there are more than one template available for that call count, and type, it will make some smart decisions on which one it picks.

1. has the dest phone been contacted before from one of these numbers, if so use it (sticky)
2. area code match
3. zipcode match
4. state match
5. pick one at random.

you can also take this one step further and do something like

| callCount | type | fromPrimary | body | active | includedStatuses | includedLists |
| --|-----|------------|-------------------------|---|-----------|----------|
| 1 | sms | 7145551212 | hello, <--first_name--> | 1 | 'AA','AB' | 998,1000 |
| 1 | sms | 7145551212 | hi, <--first_name--> | 1 | 'AA','AB' | 998,1000 |
| 1 | sms | 7145551212 | hey, <--first_name--> | 1 | 'AA','AB' | 998,1000 |
| 1 | sms | 9495551212 | hello, <--first_name--> | 1 | 'AA','AB' | 998,1000 |
| 1 | sms | 9495551212 | hi, <--first_name--> | 1 | 'AA','AB' | 998,1000 |
| 1 | sms | 9495551212 | hey, <--first_name--> | 1 | 'AA','AB' | 998,1000 |

as you can see here there are duplicate numbers, in this case FUE will find a match based on the 1-5 order above, and then pick a template from random of that call count, group, and phone number, which allows you to randomize your messages a little better.

##### email
there are two types of email, plain text, and html.

| callCount | type | fromPrimary | fromAlternate | subject | body | bodyUrl |
| --|-----|------------|-------------------------|---|-----------|----------|
| 1 | email | info@company.com | example company | email subject here | hello, <--first_name--> | link to attachment (optional) |
| 2 | email-html | info@company.com | example company | email subject here | html body here | link to attachment (optional) |


##### RVM
to send an ringless voicemail it has to be done from 2 numbers you own (with the ytel api)

| callCount | type | fromPrimary | fromAlternate | subject | body | bodyUrl |
| --|-----|------------|-------------------------|---|-----------|----------|
| 1 | rvm | 7145551212 | 9495551212 | |  | https://yoursite.com/audio.mp3 |
| 1 | rvm | 9495551212 | 7145551212 | |  | https://yoursite.com/audio.mp3 |


##### API
this allows you to post/get  to another site with lead data based on the call count. it can also be used for scheduling call backs by posting it back in based on a specific status.

you can also separate the urls by '|' and it will send multiple for the same call count, instead of randomly picking one as what happens with all other types.

| callCount | type | fromPrimary | fromAlternate | subject | body | bodyUrl |
|-----------|------|-------------|---------------|---------|------|---------|
| 1         | api  |             |               | get |  | https://yoursite.com/api/?first_name=<--first_name--> |
| 2         | api  |             |               | post |  | https://yoursite.com/api/data |

note: if using post, FUE takes all lead data it has, and everything about the template (how it was matched and so forth), merges it into an array, and posts it as JSON to whatever bodyUrl you set as your endpoint.


#### mix and match
you can mix and match different types in the same call count group. for example.

| callCount | type | fromPrimary | fromAlternate | subject | body | bodyUrl |
| --|-----|------------|-------------------------|---|-----------|----------|
| 1 | email | info@company.com | example company | email subject here | hello, <--first_name--> | link to attachment (optional) |
| 1 | rvm | 9495551212 | 7145551212 | |  | https://yoursite.com/audio.mp3 |

in this example when the lead hits call count 1, both an email and rvm will be sent at the same time. you can do this with multiple records for did matching, and sending api posts.

### ytel_followup_log
this table exists so that the engine doesn't send the same message to the same lead twice. its also a running log of sent actions.

## install
to install FollowupEngine make sure the following packages are installed

```
https://metacpan.org/pod/App::cpanminus
or
curl -L https://cpanmin.us | perl - --sudo App::cpanminus

and git
```

then to install FollowupEngine

```
git clone https://github.com/drewbeer/followupEngine.git /opt/followupEngine
cd /opt/followupEngine
sh install.sh
```

once this is done it should have created the table structure, and inserted a default record in the settings table. it will also instruct you to add a new line to your crontab.

```
# #####################
# # Ytel Followup Engine
# every minute, between 5am-8pm server time, this is a failsafe (main window is in db settings)
# #####################
* 5-20 * * * /opt/followupEngine/bin/followupEngine.pl >/dev/null 2>&1
```

### logging
default logging location is at

```
/var/log/followupEngine.log
```

the default log level is info, you can adjust this by editing the etc/log.conf file and comment out the info log and uncomment the debug.

### Misc
this code assumes that the default vicidial config file is in /etc/astguiclient.conf. you can adjust this in the etc/settings.conf file which should be created on first run. if not copy the settings.conf.default to settings.conf and adjust as needed

tables created are:
ytel_settings
ytel_followup_log
ytel_followup_templates


### UI
there is a UI but its not open sourced yet, i'm working to see if i can get that piece done, but its part of a larger project, and its all based on time.

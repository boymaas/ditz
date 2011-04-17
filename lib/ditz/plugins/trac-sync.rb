# Trac syncing ditz plugin
#
# Provides ditz <-> trac synchronization
#
# Author::  Sean Russell <seanerussell@gmail.com>
# Version:: 2010.2
#
# Command added:
#   ditz sync: synchronize issues with Trac
#
# Usage:
#   1. Add a line '- trac-sync' to the .ditz-plugins file in the project root.
#   2. Call 'ditz trac'

require 'rubygems'
require 'trac4r'
require 'ditz'
require 'logger'

module Ditz
  class Issue
    field :trac_id, :ask => false

    def log_at time, what, who, comment
      add_log_event([time, who, what, comment || ""])
      self
    end
  end

  class ScreenView
    add_to_view :issue_summary do |issue, config|
      " Trac ID: #{issue.trac_id || 'none'}\n"
    end
    add_to_view :issue_details do |issue, config|
      "Trac URL: #{config.trac_sync_url || 'none'}\n"
    end
  end

  class HtmlView
    add_to_view :issue_summary do |issue, config|
      next unless issue.trac_id
      [<<-EOS, { :issue => issue }]
<tr>
  <td class='attrname'>Trac ID:</td>
  <td class='attrval'><%= issue.trac_id %></td>
</tr>
      EOS
    end

    add_to_view :issue_details do |issue, config|
      next unless issue.trac_id
      [<<-EOS, { :issue => issue, :config => config }]
<h2>Trac Synchronization</h2>
<table>
  <tr>
    <td class='attrname'>Trac URL:</td>
    <td class='attrval'><%= config.trac_sync_url %></td>
  </tr>
</table>
      EOS
    end
  end

  # A utility class for handling Trac tickets and milestones
  class TracUtil
    # If new types or dispositions are added to either ditz or trac, they'll need
    # to be mapped here
    #
    # trac_type -> ditz_type
    TTYPE_DTYPE = { "defect" => :bugfix, 
      "enhancement" => :feature, 
      "task" => :task }
    DTYPE_TTYPE = TTYPE_DTYPE.invert
    DTYPE_TTYPE[:bug] = "defect"
    # trac_resolution -> ditz_disposition
    RES_DISPO = { "fixed" => :fixed,
      "wontfix" => :wontfix,
      "worksforme" => :wontfix,
      "invalid" => :wontfix,
      "duplicate" => :duplicate,
    }
    DISPO_RES = RES_DISPO.invert
    # But, because it isn't 1-1, fix the mapping
    DISPO_RES[ :wontfix ] = "wontfix"
    DISPO_RES[ :reorg ]   = "wontfix"
    TSTATUS_DSTATUS = { "accepted" => :in_progress,
      "repoened" => :in_progress,
      "assigned" => :unstarted,
      "new" => :unstarted,
      "closed" => :closed,
    }
    DSTATUS_TSTATUS = TSTATUS_DSTATUS.invert
    # But, because it isn't 1-1, fix the mapping
    DSTATUS_TSTATUS[ :in_progress ] = "accepted" 
    DSTATUS_TSTATUS[ :unstarted ] = "assigned" 
    DSTATUS_TSTATUS[ :paused ] = "assigned" 

    def initialize( project, config, trac, logger )
      @project, @config, @trac, @logger = project, config, trac, logger
    end

    # Find matches between tickets and issues.  First matches by
    # ticket.trac_id, and if that fails, by title
    def pair( tickets )
      rv = []
      unpaired_issues = @project.issues.clone
      @logger.debug("Have #{tickets.size} tickets")
      @logger.debug("Tickets: #{tickets.collect{|t|t.summary}.inspect}")
      for ticket in tickets 
        # Try by ID first
        issue = unpaired_issues.find { |i| ticket.id == i.trac_id }
        if issue.nil?
          issue = unpaired_issues.find { |i| ticket.summary == i.title }
        end
        # If the ID is the same but the summary isn't then it is probably a rename.
        # Hopefully.

        if issue
          # However, if we found an issue by title and the IDs don't match,
          # then somehow the ticket got deleted.  This is bad, but the only thing
          # that can be done is to sync the IDs.
          if !issue.trac_id.nil? and (issue.trac_id != ticket.id)
            @logger.error("Found a match by title, but the IDs don't match!!")
            @logger.error("\tissue has #{issue.trac_id}, ticket has #{ticket.id}")
            @logger.error("\tFixing (by sync'ing the issue's trac ID)")
            # The fix is a few lines down
            issue.trac_id = nil
          end

          @logger.info("Found ticket/issue match #{ issue.trac_id ? "by id" : "by name"}")
          # We've paired the issue, so remove it from the unpaired list
          unpaired_issues.delete(issue)
          issue.trac_id = ticket.id
        end
        rv << [ticket,issue]
      end

      # Now put the left-over, unmatched issues in with a nil ticket
      # TODO check here that none of these issues have trac_ids.
      for issue in unpaired_issues
        @logger.info("Found no match for #{issue.id[0,4]}: #{issue.title}")
        rv << [nil,issue]
      end
      rv
    end


    # Syncs ditz issues -> Trac
    def create_tickets( issues )
      rv = {}
      maybe_create_milestones
      maybe_create_components
      issues.each do |t,i| # t will always be nil
        raise "No DTYPE for #{i.type}" if DTYPE_TTYPE[ i.type ].nil?
        attrs = { 
          #"created_at" => i.creation_time,
          "type"       => DTYPE_TTYPE[ i.type ],
          "reporter"   => i.reporter || "",
          "milestone"  => i.release || "",
          "component"  => i.component || "",
          "owner"      => i.claimer,
          "status"     => DSTATUS_TSTATUS[ i.status ] || "",
          "resolution" => DISPO_RES[ i.disposition ] || ""
        }
        tid = nil
        try {
          tid = @trac.tickets.create( i.title, i.desc, attrs )
        }
        i.trac_id = tid
        try {
          rv[i] = @trac.tickets.get(tid)
        }
        raise "Got nil for a ticket we just created!" if rv[i].nil?
        try {
          @trac.query( "ticket.update", rv[i].id, "Ticket synced from ditz by #{@config.user}", attrs )
        }
        @logger.debug("Created ticket #{tid} from #{i.id[0,4]} with #{attrs.inspect}")
      end
      rv
    end


    # Syncs Trac tickets -> issues
    # tickets: [tickets,nil] -- only the tickets
    def create_issues( tickets )
      rv = {} # will contain {ticket=>new_issue}
      tickets.each do |t,i|   # i will always be nil
        # trac4r doesn't yet support resolution
        resolution = t.status == "closed" ? :fixed : nil
        release = maybe_create_release( t.milestone )
        maybe_create_component( t.component )

        if release and release.status == :released
          @logger.warn("Orphaned ticket ##{t.id}: milestone #{t.milestone} already released!")
          @logger.warn("\t#{t.summary}")
        else
          release_name = release ? release.name : nil
          attrs = {:reporter => t.reporter,
            :creation_time => t.created_at.to_time,
            :title => t.summary,
            :type  => TTYPE_DTYPE[ t.type ],
            :desc  => t.description,
            :release => release_name,
            :component => t.component,
            :status => TSTATUS_DSTATUS[ t.status ],
            :disposition => resolution,
            :references => [],
            :trac_id => t.id
          }
          @logger.debug( "Creating ticket with attributes #{attrs.inspect}" )
          issue = Ditz::Issue.create(attrs, [@config, @project])

          @project.add_issue( issue )
          @logger.info("Created issue #{issue.id[0,4]}: #{issue.title}")
          rv[t] = issue
        end
      end
      rv
    end


    # This doesn't apply the change logs to the tickets like we do with
    # issues, because the Trac XMLRPC API doesn't let us write log entries
    # directly.  So, we can't log user/timestamp changes.  Consequently,
    # the only things we do here are (a) log comments, and (b) update the
    # ticket status if it differs 
    def update_tickets( pairs )
      @logger.info("Updating tickets")
      pairs.each do |ticket, issue|
        @logger.info("Updating ticket #{ticket.id} from #{issue.id[0,4]}")
        copy_comments( ticket, issue )
        issue_last_changed = if issue.log_events.size == 0
                               issue.creation_time
                             else
                               issue.log_events[-1][0]
                             end
        @logger.debug( "Issue changed  #{issue_last_changed}" )
        @logger.debug( "Ticket changed #{ticket.updated_at.to_time}" )
        if issue_last_changed > ticket.updated_at.to_time
          attrs = {}
          attrs["summary"] = issue.title if issue.title != ticket.summary
          attrs["description"] = issue.desc if issue.desc != ticket.description
          attrs["milestone"] = issue.release if issue.release != ticket.milestone
          #attrs["milestone"] = "" unless attrs["milestone"]
          if DSTATUS_TSTATUS[issue.status] != ticket.status
            attrs["status"] = DSTATUS_TSTATUS[issue.status]
          end
          if DISPO_RES[issue.disposition] != ticket.status
            attrs["resolution"] = DISPO_RES[issue.disposition] || ""
          end
          if issue.component != ticket.component
            attrs["component"] = issue.component 
          end
          if DTYPE_TTYPE[issue.type] != ticket.type
            attrs["type"] = DTYPE_TTYPE[issue.type]
          end
          attrs["owner"] = issue.claimer
          @logger.info("Updating ticket #{ticket.id} with #{attrs.inspect}")
          try {
            @trac.query( "ticket.update", ticket.id, "Ticket synced from ditz by #{@config.user}", attrs )
          }
        end
      end
    end


    def update_issues( pairs )
      @logger.info("Updating issues")
      pairs.each do |ticket, issue|
        @logger.info( "Updating #{issue.id[0,4]} from #{ticket.id}" )
        copy_comments( issue, ticket )
        issue_last_changed = if issue.log_events.size == 0
                               issue.creation_time
                             else
                               issue.log_events[-1][0]
                             end
        @logger.debug( "Issue changed  #{issue_last_changed}" )
        @logger.debug( "Ticket changed #{ticket.updated_at.to_time}" )
        if issue_last_changed < ticket.updated_at.to_time
          issue.title = ticket.summary if issue.title != ticket.summary
          issue.desc = ticket.description if issue.desc != ticket.description
          issue.release = ticket.milestone if issue.release != ticket.milestone
          issue.claimer = ticket.owner if issue.claimer != ticket.owner
          if DSTATUS_TSTATUS[issue.status] != ticket.status
            issue.status = TSTATUS_DSTATUS[ticket.status]
          end
          # disposition what is it?
          #if DISPO_RES[issue.disposition] != ticket.status
          #  issue.disposition = RES_DISPO[ticket.status]
          #end
          if issue.component != ticket.component
            issue.component = ticket.component
          end
          if DTYPE_TTYPE[issue.type] != ticket.type
            issue.type = TTYPE_DTYPE[ticket.type]
          end
        end
      end
    end

    ############################################################################
    # Utility methods used internal to the class
    private


    def try
      tries = 0
      begin
        @logger.debug( "Try #{tries}" )
        yield
        tries = 0
      rescue Trac::TracException => err
        @logger.warn(err.message) if tries == 0
        case err.message
        when /Wrong type NilClass/, /end of file reached/
          sleep 0.5
          @logger.warn("Had to re-connect to Trac")
          @trac = Trac.new(@config.trac_sync_url, 
                           @config.trac_sync_user, 
                           @config.trac_sync_pass)
        else
          sleep 0.5
        end
        tries += 1
        if tries <= 5
          @logger.warn("Retry ##{tries}")
          retry
        else
          raise
        end
      end
    end


    def copy_comments( a, b )
      raise "Can't copy to/from nil." if a.nil? or b.nil?
      if a.instance_of? Issue
        issue, ticket = a, b
      else
        ticket, issue = a, b
      end

      cl = nil
      try {
        cl = @trac.tickets.changelog( ticket.id )
      }
      el = issue.log_events

      cl_comments = cl.find_all { |c| c[2] == "comment" }
      el_comments = el.find_all { |e| e[2] == "commented" }

      cl_comments.reject! do |c| 
        @logger.debug("Looking for #{c[4].inspect} in #{el_comments.collect{|m| m[3]}.inspect}")
        m = el_comments.find { |e| e[3] == c[4] }
        if m
          @logger.debug("Found it.")
          el_comments.delete(m)
          true
        else
          @logger.debug("Not found")
          false
        end
      end

      cl_comments.each do |c|
        unless c[4]=="" || c[4].nil? || (c[4] =~ /^Ticket synced from ditz/)
          @logger.info( "Updating issue #{issue.id} with comment #{c[4].inspect}" )
          
          unless issue.log_events.find {|e| e[0] == c[0].to_time && e[2] == "commented" && e[3] == c[4] }
            issue.log_at( c[0].to_time, "commented", c[1], c[4] )
          end
        end
      end

      if el_comments.size > 0
        @logger.debug( "Issue comments =>" )
        @logger.debug( el_comments.inspect )
        el_comments.each do |e|
          unless e[3]=="" || e[3].nil? || (e[3] =~ /^Ticket synced from ditz/)
            @logger.info( "Updating ticket #{ticket.id} with comment #{e[3].inspect}" )
            try {
              @trac.query( "ticket.update", ticket.id, e[3] )
            }
          end
        end
      end
    end

    def change_status(status, issue)
      if issue.status != status
        old_status = issue.status
        issue.status = status
        return "changed status from #{old_status} to #{status}"
      end
      nil
    end

    # Creates a ditz release, IFF it doesn't exist
    # milestone: the String name of the release to create
    def maybe_create_release( milestone )
      return nil if milestone.nil? or milestone == ""
      release = @project.releases.find { |r| r.name == milestone }
      unless release 
        @logger.info( "Creating release #{milestone.inspect}" )
        release = Ditz::Release.create({:name=>milestone}, [@config, @project])
        @project.add_release(release)
      end
      release
    end

    # Creates a ditz component, IFF it doesn't already exist
    # comp: the String name of the component to create
    def maybe_create_component( comp )
      return "" if comp.nil? or comp == ""
      @logger.debug( @project.components.inspect )
      component = @project.components.find { |r| r.name == comp }
      unless component 
        @logger.info( "Creating component #{comp}" )
        component = Ditz::Component.create({:name=>comp}, [@config, @project])
        @project.add_component(component)
      end
      component
    end

    def group_by_time(changelog)
      rv = {}
      changelog.each do |log|
        t = log[0].to_time
        rv[t] = [] unless rv[t]
        rv[t] << log
      end
      rv.sort
    end

    # Creates Trac components for all of the ditz components that are missing
    # in Trac
    # trac: the trac4r object to create the components in
    def maybe_create_components
      components = nil
      try {
        components = @trac.query("ticket.component.getAll")
      }
      @project.components.each do |component|
        next if components.include? component.name
        try {
          @trac.query("ticket.component.create", component.name, {})
        }
      end
    end

    # Creates Trac milestones for all of the ditz releases that are missing in
    # Trac
    # trac: the trac4r object to create the milestones in
    def maybe_create_milestones
      milestones = nil
      try {
        milestones = @trac.query("ticket.milestone.getAll")
      }
      @project.releases.each do |release|
        next if milestones.include? release.name
        attrs = {}
        release.log_events.each do |ev| 
          case ev[2]
          when "created"
            attrs["description"] = ev[3]
          when "released"
            attrs["completed"] = ev[0]
          end
        end
        try {
          @trac.query("ticket.milestone.create", release.name, attrs)
        }
      end
    end

    def maybe_create_resolutions
      try {
        @trac.query("ticket.milestone.create", release.name, {
          "completed" => rel,
          "description" => desc
        })
      }
    end
    def maybe_create_status
      try {
        @trac.query("ticket.milestone.create", release.name, {
          "completed" => rel,
          "description" => desc
        })
      }
    end
    def maybe_create_type
      try {
        @trac.query("ticket.milestone.create", release.name, {
          "completed" => rel,
          "description" => desc
        })
      }
    end
  end

  class Config
    field :trac_sync_url, :prompt => "URL of Trac project (without the login/xmlrpc)"
    field :trac_sync_user, :prompt => "The Trac user ID that has XMLRPC permissions"
    field :trac_sync_pass, :prompt => "The Trac password for the account"
  end

  class Operator
    operation :trac, "Sync with a Trac repository", :maybe_debug, :maybe_verbose do
      opt :debug, "Run in debug mode, for very verbose output", :short => 'd', :default => false
      opt :verbose, "Run in verbose mode", :short => 'v', :default => false
    end 
    def trac( project, config, opts, *args )
      logger = Logger.new(STDERR)
      logger.level = Logger::WARN
      logger.level = Logger::DEBUG if opts[:debug]
      logger.level = Logger::INFO if opts[:verbose]
      unless config.trac_sync_url
        logger.error( "Please run 'ditz reconfigure' and set the Trac URL" )
        return
      end
      unless config.trac_sync_user
        logger.error( "Please run 'ditz reconfigure' and set the Trac XMLRPC user name" )
        return
      end
      unless config.trac_sync_pass
        logger.error( "Please run 'ditz reconfigure' and set the Trac XMLRPC password" )
        return
      end
      trac = Trac.new(config.trac_sync_url, config.trac_sync_user, config.trac_sync_pass)
      util = Ditz::TracUtil.new( project, config, trac, logger )

      tickets = trac.query("ticket.query", "max=1000000&order=id")
      STDOUT.puts("Fetching #{tickets.size} tickets...")
      tickets.collect! {|id|
        STDOUT.print(".") ; STDOUT.flush
        trac.tickets.get(id)
      }
      STDOUT.puts
      changelogs = []

      # TODO this is really inefficient.  No need to re-update things that have 
      # already been updated, and we're re-pairing too much.  The create methods
      # could just pair in the method and return the pairs

      # Existing [ticket,issue] matches
      pairs = util.pair(tickets)
      logger.debug( "All pairs: " )
      logger.debug( pairs.collect {|t,i| [ t ? t.id : nil, i ? i.id[0,4] : nil ]}.inspect )

      # Create and update any missing issues.  new_pairs is {ticket=>new_issue} hash
      only_tickets = pairs.find_all {|m| m[1] == nil}
      STDOUT.puts("Creating new issues from #{only_tickets.size} tickets")
      new_issues = util.create_issues( only_tickets )
      STDOUT.puts("Created #{new_issues.size} new issues")
      pairs.each { |m| m[1] = new_issues[m[0]] unless m[1] }

      # Create and update any missing tickets. new_tickets is {issue=>new_ticket} hash
      only_issues = pairs.find_all {|m| m[0] == nil}
      STDOUT.puts("Creating new tickets from #{only_issues.size} issues")
      new_tickets = util.create_tickets( only_issues )
      STDOUT.puts("Created #{new_tickets.size} new tickets")
      pairs.each { |m| m[0] = new_tickets[m[1]] unless m[0] }

      # We can't create issues for releases that are already released (ditz
      # limitation), so ignore those.
      pairs.reject! { |t,i| i.nil? }
      pairs.each do |t,i| 
        if t.nil?
          logger.error("Failed to create a ticket for issue #{i.id[0,4]}, somehow.")
        end
      end

      # Now, update the issues and tickets with any changes that have occurred since
      # the last change on the partner. We don't need to update objects which caused a
      # new partner to be created... so if a ticket created a new issue, don't update
      # the ticket.
      #
      # Don't update issues that just created a new ticket
      issues_to_update = pairs.reject {|t,i| new_tickets[i] }
      STDOUT.puts("Updating #{issues_to_update.size} issues")
      logger.debug(issues_to_update.collect{|t,i| i.id[0,4] }.inspect)
      util.update_issues( issues_to_update )

      # Don't update tickets that just created a new issue
      tickets_to_update = pairs.reject {|t,i| new_issues[t] }
      STDOUT.puts("Updating #{tickets_to_update.size} tickets")
      logger.debug(tickets_to_update.collect{|t,i| t.id }.inspect)
      util.update_tickets( tickets_to_update )
    end
  end
end

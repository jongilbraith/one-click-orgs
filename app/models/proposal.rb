require 'dm-validations'

class Proposal
  include AsyncJobs
  
  include DataMapper::Resource
  
  after :create, :send_email
  has n, :votes
  has 1, :decision
  
  attr_accessor :completed, :for

  belongs_to :proposer, :class_name => 'Member', :child_key => [:proposer_member_id]
  
  property :id, Serial
  property :title, String, :nullable => false, :length => 255
  property :description, Text
  property :creation_date, DateTime, :default => Proc.new {|r,p| Time.now.to_datetime}
  property :open, Boolean, :default => true
  property :accepted, Boolean, :default => false
  property :close_date, DateTime, :default => Proc.new {|r,p| (Time.now + Constitution.get_voting_period).to_datetime}
  property :parameters, String, :length => 10000
  property :type, Discriminator 
  
  validates_present :proposer_member_id
  
  def end_date
    self.close_date
  end
  
  def votes_for
    Vote.count(:proposal_id => self.id, :for => true)
  end
  
  def votes_against
    Vote.count(:proposal_id => self.id, :for => false)
  end
  
  def total_members
     Member.count(:created_at.lt => creation_date)
  end
  
  def abstained
    member_count - total_votes
  end
  
  def total_votes
    votes_for + votes_against
  end
  
  def accepted
    votes_for > votes_against
  end
  
  def reject!
    #do some kind of email notification
  end
  
  def accepted_or_rejected
    accepted ? "accepted" : "rejected"
  end
  
  def enact!
  end
  
  def open?
    self.open
  end
  
  def closed?
    ! self.open?
  end
  
  def majority?
    num_members = Member.count(:created_at.lt => creation_date)
    return votes_for >= (num_members / 2.0).ceil
  end

  def passed?
    vs = get_voting_system
    vs.passed?(self)
  end
  
  def get_voting_system
    Constitution.get_general_voting_system
  end
    
  def close!
    passed = passed?
    raise "proposal #{self} already closed" if closed?    
    Merb.logger.info("closing proposal #{self}")
        
    Decision.create!(:proposal_id=>self.id) if passed
    self.open = 0
    self.close_date = Time.now
    self.accepted = passed
    enact! if passed
    save!
  end

  def self.serialize_parameters(params)
    params.to_json
  end
  
  def self.find_closed_early_proposals
    Proposal.all(:close_date.gt => Time.now).select { |p| p.majority? }
  end

  def self.close_due_proposals
   Proposal.all(:close_date.lt => Time.now, :open=>1).each { |p| p.close! }
  end
  
  def self.close_early_proposals
    find_closed_early_proposals.each { |p| p.close! }
  end
  
  # Called every 60 seconds in the worker process (set up at end of file)
  def self.close_proposals
    close_due_proposals
    close_early_proposals
  end
  
  def self.all_open
    all(:open => true, :close_date.gt => Time.now)
  end
  
  def self.all_failed
    all(:close_date.lt => Time.now, :order => [:close_date.desc]).select{|v| !v.accepted}
  end
  
  
  def send_email
    async_job :send_email_for, self.id
  end
  
  def self.send_email_for(proposal_id)
    proposal = Proposal.get(proposal_id)
    
    Member.all.each do |m|
      OCOMail.send_mail(ProposalMailer, :notify_creation,
        {:to => m.email, :from => 'info@oneclickor.gs', :subject => 'new one click proposal'},
        {:member => m, :proposal => proposal}
      )
    end
  end
end

# Run the close proposal every 60 seconds
AsyncJobs.periodical Proposal, 60, :close_proposals


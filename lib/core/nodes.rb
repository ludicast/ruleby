# This file is part of the Ruleby project (http://ruleby.org)
#
# This application is free software; you can redistribute it and/or
# modify it under the terms of the Ruby license defined in the
# LICENSE.txt file.
# 
# Copyright (c) 2007 Joe Kutner and Matt Smith. All rights reserved.
#
# * Authors: Joe Kutner
#

module Ruleby
  module Core 

  # This class acts as the root-node of the network.  It contains the logic
  # for building the node-network from a set of rules, and updating it
  # according to the working memory
  class RootNode          
    def initialize(working_memory)
      @working_memory = working_memory
      @type_node = nil
      @inherit_nodes = []
      @atom_nodes = [] 
      @join_nodes = []
      @terminal_nodes = []
    end
  
    # This method is invoked when a new rule is added to the system.  The
    # rule is processed and the appropriate nodes are added to the network.
    def assert_rule(rule)
      terminal_node = TerminalNode.new rule  
      build_network(rule.pattern, terminal_node)             
      @terminal_nodes.push terminal_node
    end    
            
    # When a new fact is added to working memory, or an existing one is removed
    # this method is called.  It finds any nodes that depend on it, and updates
    # them accordingly.
    def assert_fact(fact) 
      @type_node and fact.token == :plus ? @type_node.assert(fact) : @type_node.retract(fact) 
      @inherit_nodes.each do |node|
        fact.token == :plus ? node.assert(fact) : node.retract(fact) 
      end
    end
        
    # Increments the activation counter.  This is just a pass-thru to the static 
    # variable in the terminal node
    def increment_counter
      TerminalNode.increment_counter
    end
    
    # Resets the activation counter.  This is just a pass-thru to the static 
    # variable in the terminal node
    def reset_counter
      TerminalNode.reset_counter
    end
  
    # When invoked, this method returns a list of all Action|MatchContext pairs 
    # as Activations.  The list is generated when facts and rules are asserted, 
    # so no comparisions are done here (i.e. no Backward Chaining).  
    def matches(initial=true)
      agenda = Array.new
      @terminal_nodes.each do |node|
        node.activations.values.each do |a|
          if initial
            a.used = false 
            agenda.push a 
          elsif !a.used
            agenda.push a 
          end          
        end 
      end
      return agenda
    end
    
    def print
      puts 'NETWORK:'    
      @terminal_nodes.each do |n|
        n.print(' ')
      end
    end

    def child_nodes
      return @inherit_nodes + [@type_node]
    end
    
    private 
    
      # This method builds the network by starting at the bottom and recursively 
      # working its way to the top.  The recursion goes up the left side of the 
      # tree first (depth first... but our tree is up-side-down).
      #  pattern - the pattern to process (Single or Composite)
      #  out_node - the node that will be below the new node in the network
      #  side - if the out_node is a JoinNode, this marks the side 
      #  Returns a new node in the network that wraps the given pattern and 
      #  is above (i.e. it outputs to) the given node.
      def build_network(pattern, out_node, side=nil) 
        if pattern.kind_of?(ObjectPattern)
          if pattern.kind_of?(NotPattern) and (side==:left or !side)
            # a NotPattern needs to be run through a NotNode, which is a beta node.
            # So if the NotPattern is on the left (i.e. it is the first pattern),
            # then we need to add a dummy pattern in front of it.
            new_pattern = CompositePattern.new(InitialFactPattern.new, pattern)            
            return build_network(new_pattern, out_node, side)
          else 
            return create_atom_nodes(pattern, out_node, side) 
          end
        else  
          join_node = create_join_node(pattern, out_node, side)  
          build_network(pattern.left_pattern, join_node, :left)
          build_network(pattern.right_pattern, join_node, :right) 
          out_node.parent_nodes.push join_node # only used to print network
          return join_node 
        end
      end
            
      # This method is used to create the atom nodes that make up the given 
      # pattern's network.  It returns the node that is at the top of the 
      # network for the pattern.
      #   pattern - the Pattern that the created node wraps
      #   out_node - the Node that this pattern is directly above in thw network
      #   side - if the out_node is a JoinNode, this marks the side 
      def create_atom_nodes(pattern, out_node, side)       
        # TODO refactor this method so it clear and concise
        type_node = create_type_node(pattern)  
        forked = false
        parent_atom = pattern.atoms[0]
        parent_node = type_node
        
        pattern.atoms[1..-1].each do |atom|
          # If the network has been forked, we don't want to share nodes anymore
          forked = true if parent_node.forks?(parent_atom)
          
          if atom.kind_of?(SelfReferenceAtom)
            node = create_self_reference_node(atom)
          elsif atom.kind_of?(ReferenceAtom)
            node = create_reference_node(atom)
            out_node.ref_nodes.push node
          else
            node = create_property_node(atom,forked)
          end
          parent_node.add_out_node node, parent_atom
          node.parent_nodes.push parent_node
          parent_node = node
          parent_atom = atom
        end    
  
        bridge_node = create_bridge_node(pattern)
        parent_node.add_out_node bridge_node, parent_atom
        bridge_node.parent_nodes.push parent_node
        parent_node = bridge_node
        
        out_node.parent_nodes.push parent_node
        
        if out_node.kind_of?(JoinNode)
          adapter_node = create_adapter_node(side)
          parent_node.add_out_node adapter_node
          parent_node = adapter_node
        end   
        
        parent_node.add_out_node out_node            
        compare_to_wm(type_node)       
        return type_node     
      end
          
      # Creates a JoinNode, puts it at the middle of the network, and stores
      # the node below it into its memory. 
      #   pattern - the Pattern that the created node wraps
      #   out_node - the Node that this pattern is directly above in thw network
      #   side - if the out_node is a JoinNode, this marks the side 
      def create_join_node(pattern, out_node, side)      
        if (pattern.right_pattern.kind_of?(NotPattern))  
          join_node = NotNode.new 
        else
          join_node = JoinNode.new    
        end
        
        @join_nodes.push(join_node)      
        parent_node = join_node
        if out_node.kind_of?(JoinNode)
          adapter_node = create_adapter_node(side)
          parent_node.add_out_node adapter_node
          parent_node = adapter_node
        end         
        parent_node.add_out_node out_node      
        return join_node      
      end
      
      def create_type_node(pattern)
        if InheritsPattern === pattern
          node = InheritsNode.new pattern.atoms[0]
          @inherit_nodes.each do |inode|
            return inode if inode.shareable? node
          end
          @inherit_nodes << node
          return node
        else
          return (@type_node ||= TypeNode.new pattern.atoms[0])
        end
      end
      
      def create_bridge_node(pattern)
        return BridgeNode.new(pattern)
      end
      
      def create_property_node(atom,forked)
        node = atom.kind_of?(EqualsAtom) ? EqualsNode.new(atom) : PropertyNode.new(atom)
        @atom_nodes.each {|n| return n if n.shareable? node} unless forked
        @atom_nodes.push node
        return node
      end
      
      def create_self_reference_node(atom)   
        node = SelfReferenceNode.new atom
        @atom_nodes.push node
        return node
      end
      
      def create_reference_node(atom)      
        node = ReferenceNode.new atom
        @atom_nodes.push node
        return node
      end
      
      def create_adapter_node(side)
        if side == :left
          return LeftAdapterNode.new
        else
          return RightAdapterNode.new
        end
      end
      
      # This method is used to update each TypeNode based on the facts in 
      # working memory.  It can be a costly operation because it iterates over 
      # EVERY fact in working memory.  It should only be used when a new rule is 
      # added.
      def compare_to_wm(type_node)            
        @working_memory.each_fact do |fact| 
          type_node.retract fact
          type_node.assert fact
        end
      end  
  end
  
  # Any node in the network that needs to be printed extends this class.  It
  # provides handles to the nodes above it in the network.  These are not used 
  # for matching (i.e. no backward-chaining).
  class Printable  
    attr_reader:parent_nodes   
    
    def initialize
      # this is only used for printing the network, not for matching
      @parent_nodes = [] 
    end
    
    def print(tab)
      puts tab + to_s
      @parent_nodes.each do |out_node|
        out_node.print('  '+tab)
      end
    end
  end
  
  # Base Node class used by all nodes in the network that do some kind 
  # of matching.
  class Node < Printable       
    # This method determines if all common tags have equal values.  If any 
    # values are not equal then the method returns false.
    def resolve(mr1, mr2)    
      mr1.variables.each_key do |t1|
        mr2.variables.each_key do |t2|
          if t2 == t1 && mr1.fact_hash[t1] != mr2.fact_hash[t2]
            return false 
          end
        end
      end 
      return true
    end
  end
  
  # This is the base class for all nodes in the network that output to some 
  # other node (i.e. they are not at the bottom). It contains methods for 
  # propagating match results.
  class ParentNode < Node    
    attr_reader :child_nodes
    def initialize()
      super
      @out_nodes = []   
    end   
    
    def add_out_node(node,atom=nil)
      unless @out_nodes.index node
        @out_nodes.push node
      end
    end
    
    # returns true if this node is already being used for the same atom.  That 
    # is, if it is used again it will fork the network (or the network may 
    # already be forked).
    def forks?(atom)
      return !@out_nodes.empty?
    end
    
    def retract(fact)
      propagate_retract(fact)
    end    
    
    def propagate_retract(fact,out_nodes=@out_nodes)
      out_nodes.each do |out_node|
        out_node.retract(fact)
      end
    end
    
    def assert(assertable)
      propagate_assert(assertable)
    end
    
    def propagate_assert(assertable,out_nodes=@out_nodes)
      out_nodes.each do |out_node|
        out_node.assert(assertable)
      end
    end
  end
  
  # This is a base class for all single input nodes that match facts based on
  # some properties.  It is essentially a wrapper for an Atom. These nodes make
  # up the Alpha network.
  class AtomNode < ParentNode  
    attr_reader:atom    
    def initialize(atom)
      super()
      @atom = atom 
    end
    
    def ==(node)
      return AtomNode === node && @atom == node.atom
    end
    
    def shareable?(node)
      return @atom.shareable?(node.atom)
    end
    
    def to_s
      super + " - #{@atom.method}"
    end
  end
  
  # This is a base class for any node that hashes out_nodes by value.  A node 
  # that inherits this class does not evaluate each condition, instead it looks
  # up the expected value in the hash, and gets a list of out_nodes.
  class HashedNode < AtomNode
    def initialize(atom)
      super
      @values = {}
      @values.default = []
    end
    
    # returns true if this node is already being used for the same atom.  That 
    # is, if it is used again it will fork the network (or the network may 
    # already be forked).
    def forks?(atom)      
      k = hash_by(atom)   
      return !@values[k].empty?
    end
    
    def add_out_node(node,atom) 
      k = hash_by(atom)
      v = @values[k]
      if v.empty?
        @values[k] = [node]
      elsif !v.index node
        @values[k] = v << node
      end
    end
    
    def retract(fact)
      propagate_retract fact, @values.values.flatten
    end
    
    def assert(fact)     
      k = fact.object.send(@atom.method)
      propagate_assert fact, @values[k] 
    rescue NoMethodError => e
      # If the method does not exist, it is the same as if it evaluted to 
      # false, and the network traverse stops
    end
  end
  
  # This node class is used to match the type of a fact.  In this case the type
  # is matched exactly (ignoring inheritance).
  class TypeNode < HashedNode    
    def hash_by(atom) 
      atom.deftemplate.clazz
    end
  end
  
  # This class is used for the same purpose as the TypeNode, but it matches 
  # if the fact's inheritance chain includes the specified class.  
  class InheritsNode < TypeNode
    def assert(fact)
      @values.each do |clazz,nodes| 
        propagate_assert fact, nodes if clazz === fact.object
      end
    end
  end
  
  # This node class is used for matching properties of a fact.
  class PropertyNode < AtomNode
    def assert(fact)
      begin
        val = fact.object.send(@atom.method)   
      rescue NoMethodError => e
        # If the method does not exist, it is the same as if it evaluted to 
        # false, and the network traverse stops
        return
      end
      super if @atom.proc.call(val)
    end
  end
  
  # This node class is used for matching properties of a fact where the 
  # condition is a simple '=='.  Instead of evaluating the condition, this node
  # will pull from a hash.  This makes it significatly fast when it is shared.
  class EqualsNode < HashedNode    
    def hash_by(atom)
      atom.value
    end   
  end  
  
  # This node class is used to match properties of one with the properties
  # of any other already matched fact.  It differs from the other AtomNodes 
  # because it does not perform any inline matching.  The match method is only
  # invoked by the two input node.
  class ReferenceNode < AtomNode    
    def match(left_context,right_fact)
      val = right_fact.object.send(@atom.method)  
      args = [val]            
      match = left_context.match
      @atom.vars.each do |var|
        args.push match.variables[var]   
      end    
      begin
        if @atom.proc.call(*args) 
          m = MatchResult.new(match.variables.clone, true, 
                              match.fact_hash.clone, match.recency)
          m.recency.push right_fact.recency
          m.fact_hash[@atom.tag] = right_fact.id
          m.variables[@atom.tag] = val 
          return m
        end
      rescue NoMethodError => e    
        # If the method does not exist, it is the same as if it evaluted to 
        # false, and the network traverse stops
      end
      return MatchResult.new
    end  
  end
  
  # This node class is used to match properties of a fact with other properties
  # of itself.  Unlike ReferenceAtom it does perform inline matching. 
  class SelfReferenceNode < AtomNode    
    def assert(fact)      
      propagate_assert fact if match fact
    end
    
    def match(fact)
      args = [fact.object.send(@atom.method)]
      @atom.vars.each do |var|
        args.push fact.object.send(var)   
      end   
      return @atom.proc.call(*args) 
    end
  end
  
  # The BridgeNode is used to bridge the alpha network to either the beta 
  # network, or to the terminal nodes.  It creates a partial match from the
  # pattern and atoms above it in the network.  Thus, there is one bridge node
  # for each pattern (assuming they aren't shared).
  class BridgeNode < ParentNode 
    def initialize(pattern)
      super()
      @pattern =  pattern
    end
  
    def propagate_assert(fact)          
      # create the partial match
      mr = MatchResult.new
      mr.is_match = true      
      mr.recency.push fact.recency
      @pattern.atoms.each do |atom|
        mr.fact_hash[atom.tag] = fact.id
        if atom == @pattern.head
          # HACK its a pain to have to check for this, can we make it special
          mr[atom.tag] = fact.object
        else
          mr[atom.tag] = fact.object.send(atom.method) 
        end
      end
      super(MatchContext.new(fact,mr))
    end
  end  
    
  # This class is used to plug nodes into the left input of a two-input JoinNode
  class LeftAdapterNode < ParentNode
    def propagate_assert(context)
      @out_nodes.each do |out_node|
        out_node.assert_left(context)
      end
    end
    
    def propagate_retract(fact)
      @out_nodes.each do |out_node|
        out_node.retract_left(fact)
      end
    end
  end
  
  # This class is used to plug nodes into the right input of a two-input 
  # JoinNode
  class RightAdapterNode < ParentNode    
    def propagate_assert(context)
      @out_nodes.each do |out_node|
        out_node.assert_right(context)
      end
    end
  
    def propagate_retract(fact)
      @out_nodes.each do |out_node|
        out_node.retract_right(fact)
      end
    end
  end
  
  # This class is a two-input node that is used to create a cross-product of the
  # two network branches above it.  It keeps a memory of the left and right 
  # inputs and compares new facts to each.  These nodes make up what is called
  # the Beta network.
  class JoinNode < ParentNode
    
    attr:ref_nodes,true
    
    def initialize
      super
      @left_memory = {}
      @right_memory = {} 
      @ref_nodes = []
    end
    
    def retract_left(fact)
      @left_memory.delete(fact.id)
      propagate_retract(fact)
    end
    
    def retract_right(fact)
      @right_memory.delete(fact.id)
      propagate_retract(fact)
    end
  
    def assert_left(context)
      add_to_left_memory(context)
      @right_memory.values.each do |right_context|
        mr = match_ref_nodes(context,right_context)      
        if (mr.is_match)
          new_context = MatchContext.new context.fact, mr  
          propagate_assert(new_context)
        end
      end
    end
    
    def assert_right(context)
      @right_memory[context.fact.id] = context
      @left_memory.values.flatten.each do |left_context|
        mr = match_ref_nodes(left_context,context)      
        if (mr.is_match)
          new_context = MatchContext.new context.fact, mr                
          propagate_assert(new_context)
        end
      end
    end    
        
    def to_s
      return "#{self.class}:#{object_id} | #{@left_memory.values} | #{@right_memory}"
    end
    
    private    
      def match_ref_nodes(left_context,right_context)
        mr = right_context.match
        if @ref_nodes.empty?
          return left_context.match.merge(mr)
        else
          @ref_nodes.each do |ref_node|
            ref_mr = ref_node.match(left_context, right_context.fact)
            if ref_mr.is_match
              mr = mr.merge ref_mr
            else
              return MatchResult.new
            end
          end
          return mr
        end
      end
      
      def add_to_left_memory(context)
        lm = @left_memory[context.fact.id]
        lm = [] unless lm      
        lm.push context
        @left_memory[context.fact.id] = lm      
        # QUESTION for a little while we were having trouble with duplicate 
        # contexts being added to the left_memory.  Double check that this is 
        # not happening
      end
      
      def propagate_retract_resolve(match)
        @out_nodes.each do |o|
          o.retract_resolve(match)
        end
      end
      
      def retract_resolve(match)
        # in this method we retract an existing match from memory if it resolves
        # with the match given.  It would probably be better to check if it 
        # resolves with a list of facts.  But the system is not set up for
        # that yet.
        @left_memory.each do |fact_id,contexts|
          value.delete_if do |left_context|          
            resolve(left_context.match, match)
          end        
        end
      end
  end
  
  # This node class is used when a rule is looking for a fact that does not 
  # exist.  It is a two-input node, and thus has some of the properties of the
  # JoinNode.  NOTE it has not clear how this will work if the NotPattern is
  # declared as the first pattern in a rule.
  class NotNode < JoinNode
    def initialize
      super
    end
    
    def retract_left(fact)
      @left_memory.delete(fact.id)
      propagate_retract(fact)
    end
    
    def retract_right(fact)
      right_context = @right_memory.delete(fact.id)  
      unless right_context == @right_memory.default
        unless @ref_nodes.empty? && !@right_memory.empty?
          @left_memory.values.each do |lm|
            lm.each do |left_context|
              # TODO we should cache the matches on the left that were unmatched 
              # by a result from a NotPattern.  We could hash them by the right 
              # match that caused this.  That we way we would not have to 
              # re-compare the the left and right matches.
              if match_ref_nodes(left_context,right_context)      
                propagate_assert(left_context)
              end
            end
          end   
        end
      end
    end
  
   def assert_left(context)    
      add_to_left_memory(context)      
      if @ref_nodes.empty? && @right_memory.empty?
        propagate_assert(context)
      else
        propagate = true
        @right_memory.values.each do |right_context|
          if match_ref_nodes(context,right_context)     
            propagate = false
            break
          end
        end
        propagate_assert(context) if propagate
      end
    end
    
    def assert_right(context)                    
      @right_memory[context.fact.id] = context
      if @ref_nodes.empty?
        @left_memory.values.flatten.each do |left_context|
          propagate_retract_resolve(left_context.match)
        end
      else
        @left_memory.values.flatten.each do |left_context|
          if match_ref_nodes(left_context,context)
            # QUESTION is there a more efficient way to retract here?
            propagate_retract_resolve(left_context.match)
          end
        end
      end
    end
    
    # NOTE this returns a boolean, while the other classes return a MatchResult
    def match_ref_nodes(left_context,right_context)
      @ref_nodes.each do |ref_node|
        ref_mr = ref_node.match(left_context, right_context.fact)
        unless ref_mr.is_match
          return false
        end
      end
      return true
    end
    private:match_ref_nodes
  end
  
  # This class represents the bottom node in the network.  There is a one to one
  # relation between TerminalNodes and Rules.  A terminal node acts as a wrapper
  # for a rule.  The class is responsible for keeping a memory of the 
  # activations that have been generated by the network.
  class TerminalNode < Node
    @@counter = 0
  
    def initialize(rule)
      super()
      @rule = rule
      @activations = MultiHash.new  
    end
    attr_reader:activations
  
    def assert(context)
      match = context.match
      a = Activation.new(@rule.action, match, @@counter)
      @activations.add match.fact_ids, a
    end
    
    def retract(fact)
      @activations.remove fact.id
    end
    
    def satisfied?
      return !@activations.values.empty? 
    end  
    
    def to_s
      return "TerminalNode:#{object_id} | #{@activations.values}"
    end
    
    def retract_resolve(match)
      # in this method we retract an existing activation from memory if its 
      # match resolves with the match given.  It would probably be better to 
      # check if it resolves with a list of facts.  But the system is not set up
      # for that yet.
      @activations.delete_if do |activation|
        resolve(activation.match, match)
      end
    end    
    
    def self.increment_counter
      @@counter = @@counter + 1
    end
    
    def self.reset_counter
      @@counter = 0
    end
  end

  end
end
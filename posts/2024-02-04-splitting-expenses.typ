#import "../template.typ": page

#show: page.with(
  title: "Algorithms to split group expenses",
  subtitle: "Posted on February 4, 2024",
)

= The problem

When traveling with friends or family it is typical that some some people will pay for things that others will also benefit from. Maybe Joe pays for the rented place, Jane pays for everyone's dinner one night, Bob buys himself and Alice lunch some day.

The question then is how to calculate how much each person owes the others at the end of the trip. In this article I'll try to devise different schemes and look at reducing the amount of necessary transactions to make everyone even.

This is a very simple problem, so one might wonder why an post. For one, devising a formal proof that the intuitive algorithm works was fun, particularly because I haven't done maths since graduating 10 years ago. And also because it was humbling that such a simple problem got me so immersed, even terribly misled (I'll explain why in the post) while solving it.

== A first solution

Suppose four friends, Joe, Jane, Alice and Bob, travel together, and that we know all the spendings during the trip and who benefited from them, as such:

#table(
  columns: 5,
  [*Payer*], [*Total value payed*], [*Description*], [*Who benefited*], [*Each benefited*],
  [Joe], [1000.00], [Rent], [All four], [250.00],
  [Jane], [100.00], [Dinner], [All four], [25.00],
  [Bob], [50.00], [Lunch], [Bob, Alice], [25.00],
  [Bob], [15.00], [Sunscreen], [Bob (himself)], [15.00],
)

Knowing there are $p = 4$ participants, we can obtain how much each person benefited from each payment. Everyone benefited $1000.00/4 = 250.00$ from rent and $100.00/4 = 25.00$ from dinner, for example.

If we look at Joe, he spent $1000.00$ but benefited only $250.00 + 25.00$ from rent and dinner, so he must be paid $1000.00 - 275.00 = 725.00$ in total at the end of the trip.

Alice is very different. She didn't pay for anything and benefited $250.00 + 25.00 + 25.00 = 300.00$ from rent, dinner and lunch. She will have to pay Bob, Jane and Joe for that.

The last line is just Bob buying himself sunscreen. We can safely ignore it.

It isn't hard to build a $p dot (p-1)/2$ sized matrix with every pair of participants in it to determine how much each owes another from this. However, each person needs to pay $(p-1)/2$ other participants in the worst-case scenario and non-worst-case scenarios can still involve a lot of payments (Jane only has to pay Joe in our example, but Alice has to pay 3 people). Even if someone's only on the receiving end, it will be inconvenient for them to check they received the right amount of money if it's split across multiple transactions. This gets tedious as more participants join. We can do better.

== Minimizing the number of transactions

One alternative is to build a sequence of transactions such that each person in this chain receives a payment from the previous person and pays the next such that the difference in value is their net debt, i.e. total value benefited - total value payed.

To make sure we don't get any negative payments in our list, we sort it with users that are more indebted first, less indebted last. This is what our list would look like for our example:

#table(
  columns: 4,
  [*Order*], [*From*], [*To*], [*Amount*],
  [1], [Alice], [Bob], [$300.00$],
  [2], [Bob], [Jane], [$550.00$],
  [3], [Jane], [Joe], [$725.00$],
)

With respect to both incoming and outgoing transactions, this is very nice: in the worst-case scenario all but one participant make one single payment and receive one single payment, one participant receives a single payment and makes none.

Going forward, let's call this the canonical solution.

== Payment orders of non canonical solutions

Previously we sorted participants with most indebted first to avoid negative values in payments. But there are other possible arrangements, such as the one below:

#table(
  columns: 4,
  [*Order*], [*From*], [*To*], [*Amount*],
  [1], [Bob], [Alice], [$250.00$],
  [2], [Alice], [Jane], [$550.00$],
  [3], [Jane], [Joe], [$725.00$],
)

There is no single order that avoids negative payments. If we enumerate transactions from $t_1$ to $t_(p-1)$, a transaction $t_x$ from participant $x$ with net debt $d_x$ is defined by:

$ t_x = t_(x-1) + d_x $

If we expand $d_x = b_x - s_x$ (value benefited minus value spent) and require non-negative transactions:

$ t_x = t_(x-1) + b_x - s_x >= 0 $

Notice that if $t_x$ is equal to $0$ for some participant, it means they can be skipped and make the chain even shorter (algorithmically we could even filter those participants out at an earlier stage). Let's define the base case $t_0 = 0$ so that $t_1$ is well defined, and write down the first few terms of the series:

$ t_1 = b_1 - s_1 $
$ t_2 = t_1 + b_2 - s_2 $
$ t_3 = t_2 + b_3 - s_3 $
$ ... $
$ t_(p-1) = t_(p-2) + b_(p-1) - s_(p-1) $

Now, any order of participants $1, 2, 3, ..., p-1$ that you assign and keeps all of the equations above non-negative should be fine. But let's keep exploring. If we add all equations from the top up to some arbitrary $t_x$, what do we get?

$ t_x = b_1 + b_2 + ... + b_x - (s_1+s_2+...+s_x) $

This is equivalent to saying that a participant $x$ will transfer the amount of money that is the net debt of all previous participants and also of themselves. Despite it being intuitively "obvious" that the canonical solution must work, the $b - s$ net values become increasingly negative when we reach participants that spent more than they benefited. So can we prove that sorting participants by their $b - s$ in descending order always yields positive numbers for all $t_x$? Let's try by induction.

== Proving there are no negative transactions in the canonical solution, by induction

Given a number of participants and filtering out those with $b - s = 0$, suppose $p$ participants remain (otherwise there's no problem to solve). Because $sum b_x - s_x = 0$, there must be at least one participant with positive $b - s$ and at least one with negative $b - s$. Let's expand that summation so we can see more clearly:

$ sum b_x - s_x = b_1 - s_1 + b_2 - s_2 + ... + b_p - s_p = 0 $

Assigning participants in decreasing order of $b - s$, we know $b_1 - s_1 > 0$ and $b_p - s_p < 0$. With help from the sum above, let's evaluate $t_(p-1)$:

$ t_(p-1) = b_1 - s_1 + b_2 - s_2 + ... + b_(p-1) - s_(p-1) = -(b_p - s_p) > 0 $

So $t_(p-1)$ must be positive as well. But what about $t_(p-2)$?

$ t_(p-2) = b_1 - s_1 + b_2 - s_2 + ... + b_(p-2) - s_(p-2) = -(b_p - s_p) - (b_(p-1) - s_(p-1)) $

We don't know the sign of $b_(p-1) - s_(p-1)$. But if it's negative, then the right-hand side of the equation helps us determine that $t_(p-2)$ is positive. If it is positive, then because terms are sorted all the previous $b - s$ are also positive, and the left-hand side of the equation shows $t_(p-2)$ should also be positive.

It's easy to extend this to all other terms and see all terms $t_x$ are positive. ◼

== Are negative transactions really a problem?

We went through great effort to prove the canonical solution only contains positive transactions, but would those actually be a problem?

Remember that $b_"Bob" = 250.00$, $b_"Jane" = 175.00$, $b_"Alice" = 300.00$ and $b_"Joe" = -725.00$.

If we create a sequence in the following arbitrary order: Jane -> Joe -> Bob > Alice, we get this:

#table(
  columns: 4,
  [*Order*], [*From*], [*To*], [*Amount*],
  [1], [Jane], [Joe], [$175.00$],
  [2], [Joe], [Bob], [$-550.00$],
  [3], [Bob], [Alice], [$-300.00$],
)

With negative transactions being paid in the other direction, this solution still satisfies the individual $b$ values (by construction), which when you think about it, is the only thing that truly matters.

My initial attachment to having only non-negative transactions was a silly one. We can put participants in any order as long as we apply $t_i = t_(i-1) + b_i$. Money will leave indebted participants' pockets and reach "credited" participants' pockets correctly one way or another, by construction.

This does change the distribution of transactions, though, as now Joe will receive two transactions instead of just one. Still, the nicest properties are still there: each participant takes part in at most two transactions and the total number of transactions is $p - 1$. It's easy to see that will always be the case, since no name appears in more than 2 lines in the table.

This is the source of my embarassment: there's nothing wrong with negative transactions. As usual, I was too keen on working with formalism to prove a property that would restrict the problem. Looking for restrictions is sane, but using formalism too soon to get there instead of developing an intuition around the problem is something I have always done, and it has once again gotten in my way, even for such a simple problem. In the end, I proved an unnecessary restriction, and it wasn't hard to see it by just looking at the transactions table and reasoning informally.

I considered not publishing this post, but thought maybe it helps me find other people that suffer from "formalitis" and get some tips. Please comment if you have any.
